package registry

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	genericapirequest "k8s.io/apiserver/pkg/endpoints/request"
	"k8s.io/apiserver/pkg/registry/rest"
	"k8s.io/apiserver/pkg/storage"
	"k8s.io/klog/v2"

	"github.com/alibaba/higress/api-server/pkg/utils"
	"github.com/fsnotify/fsnotify"
	"github.com/google/uuid"
)

const fileChangeProcessInterval = 100 * time.Millisecond
const defaultNamespace = "higress-system"
const tmpFileTtl = 5 * time.Second

var fileBeingProcessedError = errors.New("file is being processed")

var _ rest.StandardStorage = &fileREST{}
var _ rest.Scoper = &fileREST{}
var _ rest.Storage = &fileREST{}

// NewFileREST instantiates a new REST storage.
func NewFileREST(
	groupResource schema.GroupResource,
	codec runtime.Codec,
	rootPath string,
	extension string,
	isNamespaced bool,
	singularName string,
	newFunc func() runtime.Object,
	newListFunc func() runtime.Object,
	attrFunc storage.AttrFunc,
) (REST, error) {
	if attrFunc == nil {
		if isNamespaced {
			attrFunc = storage.DefaultNamespaceScopedAttr
		} else {
			attrFunc = storage.DefaultClusterScopedAttr
		}
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("failed to create file watcher for %s: %v", groupResource.Resource, err)
	}
	// file REST
	f := &fileREST{
		TableConvertor: rest.NewDefaultTableConvertor(groupResource),
		groupResource:  groupResource,
		codec:          codec,
		objRootPath:    filepath.Join(rootPath, strings.ToLower(groupResource.Resource)),
		objExtension:   extension,
		isNamespaced:   isNamespaced,
		singularName:   singularName,
		newFunc:        newFunc,
		newListFunc:    newListFunc,
		attrFunc:       attrFunc,
		dirWatcher:     watcher,
		fileWatchers:   make(map[string]*fileWatch, 10),
	}
	if err := f.startDirWatcher(); err != nil {
		return nil, err
	}
	return f, nil
}

type fileREST struct {
	rest.TableConvertor
	groupResource schema.GroupResource
	codec         runtime.Codec
	objRootPath   string
	objExtension  string
	isNamespaced  bool
	singularName  string

	fileContentCache        map[string]runtime.Object
	pendingFileChanges      map[string]time.Time
	fileChangeMutex         sync.Mutex
	fileChangeProcessTicker *time.Ticker
	dirWatcher              *fsnotify.Watcher
	fileWatchers            map[string]*fileWatch
	fileWatchersMutex       sync.RWMutex

	newFunc     func() runtime.Object
	newListFunc func() runtime.Object
	attrFunc    storage.AttrFunc
}

func (f *fileREST) GetSingularName() string {
	return f.singularName
}

func (f *fileREST) Destroy() {
	if f.dirWatcher != nil {
		_ = f.dirWatcher.Close()
	}
}

func (f *fileREST) startDirWatcher() error {
	if err := utils.EnsureDir(f.objRootPath); err != nil {
		return fmt.Errorf("unable to create data dir: %v", err)
	}
	f.pendingFileChanges = make(map[string]time.Time)
	f.fileContentCache = make(map[string]runtime.Object, 100)
	if err := f.visitDir(f.objRootPath, f.objExtension, f.newFunc, f.codec, func(path string, obj runtime.Object) {
		f.fileContentCache[path] = obj
	}); err != nil {
		return fmt.Errorf("failed to sync file cache [%s]: %v", f.objRootPath, err)
	}
	if err := f.dirWatcher.Add(f.objRootPath); err != nil {
		return fmt.Errorf("unable to watch data dir: %v", err)
	}

	if f.fileChangeProcessTicker == nil {
		f.fileChangeProcessTicker = time.NewTicker(fileChangeProcessInterval)
		f.pendingFileChanges = make(map[string]time.Time)
		go func(f *fileREST) {
			for {
				<-f.fileChangeProcessTicker.C
				f.fileChangeProcessTickerFunc()
			}
		}(f)
	}

	go func() {
		for {
			select {
			case event, ok := <-f.dirWatcher.Events:
				if !ok {
					return
				}
				f.processDirWatcherEvents(event)
			case err, ok := <-f.dirWatcher.Errors:
				if !ok {
					return
				}
				klog.Errorf("error received from watcher: %v", err)
			}
		}
	}()
	return nil
}

func (f *fileREST) processDirWatcherEvents(event fsnotify.Event) {
	if !strings.HasSuffix(event.Name, f.objExtension) {
		return
	}

	if event.Has(fsnotify.Create) || event.Has(fsnotify.Write) {
		(func() {
			f.fileChangeMutex.Lock()
			defer f.fileChangeMutex.Unlock()

			f.pendingFileChanges[event.Name] = time.Now()
		})()
	} else if event.Has(fsnotify.Remove) || event.Has(fsnotify.Rename) {
		(func() {
			f.fileChangeMutex.Lock()
			defer f.fileChangeMutex.Unlock()

			delete(f.pendingFileChanges, event.Name)
			obj := f.fileContentCache[event.Name]
			delete(f.fileContentCache, event.Name)

			if obj != nil {
				f.notifyWatchers(watch.Event{
					Type:   watch.Deleted,
					Object: obj,
				})
			}
		})()
	}
}

func (f *fileREST) fileChangeProcessTickerFunc() {
	f.fileChangeMutex.Lock()
	defer f.fileChangeMutex.Unlock()

	now := time.Now()

	pendingChangesToKeep := make(map[string]time.Time)
	for path, t := range f.pendingFileChanges {
		if now.Sub(t) < fileChangeProcessInterval {
			pendingChangesToKeep[path] = t
			continue
		}
		if obj, err := f.read(f.codec, path, f.newFunc); err == nil {
			eventType := watch.Modified
			if f.fileContentCache[path] == nil {
				eventType = watch.Added
			}
			f.fileContentCache[path] = obj
			f.notifyWatchers(watch.Event{
				Type:   eventType,
				Object: obj,
			})
		}
	}
	f.pendingFileChanges = pendingChangesToKeep
}

func (f *fileREST) notifyWatchers(ev watch.Event) {
	f.fileWatchersMutex.RLock()
	defer f.fileWatchersMutex.RUnlock()
	accessor, _ := meta.Accessor(ev.Object)
	klog.Infof("event %s %s %s/%s count(watcher)=%d", ev.Type, ev.Object.GetObjectKind(), accessor.GetNamespace(), accessor.GetName(), len(f.fileWatchers))
	for _, w := range f.fileWatchers {
		w.ch <- ev
	}
}

func (f *fileREST) New() runtime.Object {
	return f.newFunc()
}

func (f *fileREST) NewList() runtime.Object {
	return f.newListFunc()
}

func (f *fileREST) NamespaceScoped() bool {
	return f.isNamespaced
}

func (f *fileREST) Get(
	ctx context.Context,
	name string,
	options *metav1.GetOptions,
) (runtime.Object, error) {
	obj, err := f.read(f.codec, f.objectFileName(ctx, name), f.newFunc)
	if obj == nil && err == nil {
		requestInfo, ok := genericapirequest.RequestInfoFrom(ctx)
		var groupResource = schema.GroupResource{}
		if ok {
			groupResource.Group = requestInfo.APIGroup
			groupResource.Resource = requestInfo.Resource
		}
		return nil, apierrors.NewNotFound(groupResource, name)
	}
	klog.Infof("[%s] %s got", f.groupResource, name)
	if err == nil {
		return obj, nil
	}
	return obj, apierrors.NewInternalError(err)
}

func (f *fileREST) normalizeObject() {

}

func (f *fileREST) List(
	ctx context.Context,
	options *metainternalversion.ListOptions,
) (runtime.Object, error) {
	label := labels.Everything()
	if options != nil && options.LabelSelector != nil {
		label = options.LabelSelector
	}
	field := fields.Everything()
	if options != nil && options.FieldSelector != nil {
		field = options.FieldSelector
	}

	predicate := f.predicateFunc(label, field)

	newListObj := f.NewList()
	v, err := getListPrt(newListObj)
	if err != nil {
		return nil, apierrors.NewInternalError(err)
	}

	count := 0
	if err := f.visitDir(f.objRootPath, f.objExtension, f.newFunc, f.codec, func(path string, obj runtime.Object) {
		if ok, err := predicate.Matches(obj); err == nil && ok {
			count++
			appendItem(v, obj)
		}
	}); err != nil {
		return nil, apierrors.NewInternalError(err)
	}

	klog.Infof("[%s] list count=%d", f.groupResource, count)

	return newListObj, nil
}

func (f *fileREST) Create(
	ctx context.Context,
	obj runtime.Object,
	createValidation rest.ValidateObjectFunc,
	options *metav1.CreateOptions,
) (runtime.Object, error) {
	if createValidation != nil {
		if err := createValidation(ctx, obj); err != nil {
			return nil, apierrors.NewInternalError(err)
		}
	}

	//if f.isNamespaced {
	//	// ensures namespace dir
	//	ns, ok := genericapirequest.NamespaceFrom(ctx)
	//	if !ok {
	//		return nil, ErrNamespaceNotExists
	//	}
	//	if err := utils.EnsureDir(filepath.Join(f.objRootPath, ns)); err != nil {
	//		return nil, err
	//	}
	//}

	accessor, err := meta.Accessor(obj)
	if err != nil {
		return nil, apierrors.NewInternalError(err)
	}

	name := accessor.GetName()

	filename := f.objectFileName(ctx, name)

	if utils.Exists(filename) {
		return nil, apierrors.NewConflict(f.groupResource, name, ErrItemAlreadyExists)
	}

	accessor.SetCreationTimestamp(metav1.NewTime(time.Now()))
	accessor.SetResourceVersion("1")

	if err := utils.EnsureDir(f.objRootPath); err != nil {
		panic(fmt.Sprintf("unable to create data dir: %s", err))
	}
	if err := f.write(f.codec, filename, obj); err != nil {
		if errors.Is(err, fileBeingProcessedError) {
			return nil, apierrors.NewConflict(f.groupResource, name, err)
		}
		return nil, apierrors.NewInternalError(err)
	}

	f.notifyWatchers(watch.Event{
		Type:   watch.Added,
		Object: obj,
	})

	return obj, nil
}

func (f *fileREST) Update(
	ctx context.Context,
	name string,
	objInfo rest.UpdatedObjectInfo,
	createValidation rest.ValidateObjectFunc,
	updateValidation rest.ValidateObjectUpdateFunc,
	forceAllowCreate bool,
	options *metav1.UpdateOptions,
) (runtime.Object, bool, error) {
	isCreate := false
	oldObj, err := f.Get(ctx, name, nil)
	if err != nil {
		if !forceAllowCreate {
			return nil, false, err
		}
		isCreate = true
	}

	updatedObj, err := objInfo.UpdatedObject(ctx, oldObj)
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}
	filename := f.objectFileName(ctx, name)

	oldAccessor, err := meta.Accessor(oldObj)
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}

	updatedAccessor, err := meta.Accessor(updatedObj)
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}

	if isCreate {
		if createValidation != nil {
			if err := createValidation(ctx, updatedObj); err != nil {
				return nil, false, apierrors.NewInternalError(err)
			}
		}

		updatedAccessor.SetCreationTimestamp(metav1.NewTime(time.Now()))
		updatedAccessor.SetResourceVersion("1")

		if err := f.write(f.codec, filename, updatedObj); err != nil {
			if errors.Is(err, fileBeingProcessedError) {
				return nil, false, apierrors.NewConflict(f.groupResource, name, err)
			}
			return nil, false, apierrors.NewInternalError(err)
		}
		f.notifyWatchers(watch.Event{
			Type:   watch.Added,
			Object: updatedObj,
		})
		return updatedObj, true, nil
	}

	if updateValidation != nil {
		if err := updateValidation(ctx, updatedObj, oldObj); err != nil {
			return nil, false, apierrors.NewInternalError(err)
		}
	}

	currentResourceVersion := oldAccessor.GetResourceVersion()
	if updatedAccessor.GetResourceVersion() != "" && currentResourceVersion != "" && updatedAccessor.GetResourceVersion() != currentResourceVersion {
		requestInfo, ok := genericapirequest.RequestInfoFrom(ctx)
		var groupResource = schema.GroupResource{}
		if ok {
			groupResource.Group = requestInfo.APIGroup
			groupResource.Resource = requestInfo.Resource
		}
		return nil, false, apierrors.NewConflict(groupResource, name, nil)
	}

	var newResourceVersion uint64
	if currentResourceVersion == "" {
		newResourceVersion = 1
	} else {
		newResourceVersion, err = strconv.ParseUint(currentResourceVersion, 10, 64)
		if err != nil {
			return nil, false, apierrors.NewInternalError(err)
		}
		newResourceVersion++
	}
	updatedAccessor.SetResourceVersion(strconv.FormatUint(newResourceVersion, 10))

	if err := f.write(f.codec, filename, updatedObj); err != nil {
		if errors.Is(err, fileBeingProcessedError) {
			return nil, false, apierrors.NewConflict(f.groupResource, name, err)
		}
		return nil, false, apierrors.NewInternalError(err)
	}

	f.notifyWatchers(watch.Event{
		Type:   watch.Modified,
		Object: updatedObj,
	})
	return updatedObj, false, nil
}

func (f *fileREST) Delete(
	ctx context.Context,
	name string,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions) (runtime.Object, bool, error) {
	filename := f.objectFileName(ctx, name)
	if !utils.Exists(filename) {
		return nil, false, apierrors.NewNotFound(f.groupResource, name)
	}

	oldObj, err := f.Get(ctx, name, nil)
	if err != nil {
		return nil, false, err
	}
	if deleteValidation != nil {
		if err := deleteValidation(ctx, oldObj); err != nil {
			return nil, false, apierrors.NewBadRequest(err.Error())
		}
	}

	if err := os.Remove(filename); err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}
	f.notifyWatchers(watch.Event{
		Type:   watch.Deleted,
		Object: oldObj,
	})
	return oldObj, true, nil
}

func (f *fileREST) DeleteCollection(
	ctx context.Context,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions,
	listOptions *metainternalversion.ListOptions,
) (runtime.Object, error) {
	newListObj := f.NewList()
	v, err := getListPrt(newListObj)
	if err != nil {
		return nil, apierrors.NewInternalError(err)
	}
	if err := f.visitDir(f.objRootPath, f.objExtension, f.newFunc, f.codec, func(path string, obj runtime.Object) {
		_ = os.Remove(path)
		appendItem(v, obj)
	}); err != nil {
		return nil, apierrors.NewInternalError(fmt.Errorf("failed walking filepath %v: %v", f.objRootPath, err))
	}
	return newListObj, nil
}

func (f *fileREST) objectFileName(ctx context.Context, name string) string {
	// Namespace is ignored here. The filepath is not namespaced.
	//if f.isNamespaced {
	//	// FIXME: return error if namespace is not found
	//	ns, _ := genericapirequest.NamespaceFrom(ctx)
	//	return filepath.Join(f.objRootPath, ns, name+f.objExtension)
	//}
	return filepath.Join(f.objRootPath, name+f.objExtension)
}

func (f *fileREST) write(encoder runtime.Encoder, filepath string, obj runtime.Object) error {
	f.normalizeObjectMeta(obj, filepath)
	buf := new(bytes.Buffer)
	if err := encoder.Encode(obj, buf); err != nil {
		return err
	}

	tmpFilepath := filepath + ".tmp"
	tmpFileWriteRetried := false
	for {
		writeErr := f.writeTempFile(buf, tmpFilepath)
		if writeErr == nil {
			break
		}
		if !errors.Is(writeErr, fileBeingProcessedError) {
			klog.Errorf("failed to write temp file [%s]: %v", tmpFilepath, writeErr)
			return writeErr
		}
		klog.Warningf("temp file already exists: %s", tmpFilepath)
		tmpFileInfo, statErr := os.Stat(tmpFilepath)
		if statErr != nil {
			klog.Errorf("failed to stat temp file [%s]: %v", tmpFilepath, statErr)
			return writeErr
		}
		if !tmpFileInfo.ModTime().Add(tmpFileTtl).Before(time.Now()) {
			klog.Infof("temp file [%s] mod time: %v. still within TTL %dms. leave it there.", tmpFilepath,
				tmpFileInfo.ModTime().Format(time.RFC3339), tmpFileTtl.Milliseconds())
			return writeErr
		}
		klog.Infof("temp file [%s] mod time: %v. already beyond TTL %dms. delete it.", tmpFilepath,
			tmpFileInfo.ModTime().Format(time.RFC3339), tmpFileTtl.Milliseconds())
		if removeErr := os.Remove(tmpFilepath); removeErr != nil {
			klog.Errorf("failed to remove temp file [%s]: %v", tmpFilepath, removeErr)
			return writeErr
		}
		if tmpFileWriteRetried {
			return writeErr
		}
		tmpFileWriteRetried = true
	}
	if err := os.Rename(tmpFilepath, filepath); err != nil {
		_ = os.Remove(tmpFilepath)
		return err
	}
	return nil
}

func (f *fileREST) writeTempFile(buf *bytes.Buffer, tmpFilepath string) error {
	tmpFile, err := os.OpenFile(tmpFilepath, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0755)
	if err != nil {
		pathError := &fs.PathError{}
		if ok := errors.As(err, &pathError); ok && errors.Is(pathError.Err, fs.ErrExist) {
			return fileBeingProcessedError
		}
		return err
	}

	defer func(f *os.File) {
		_ = f.Close()
	}(tmpFile)

	_, err = buf.WriteTo(tmpFile)
	return err
}

func (f *fileREST) read(decoder runtime.Decoder, path string, newFunc func() runtime.Object) (runtime.Object, error) {
	cleanedPath := filepath.Clean(path)
	if _, err := os.Stat(cleanedPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		} else {
			return nil, fmt.Errorf("failed to stat file [%s]: %v", path, err)
		}
	}
	content, err := os.ReadFile(cleanedPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read file [%s]: %v", path, err)
	}
	newObj := newFunc()
	decodedObj, _, err := decoder.Decode(content, nil, newObj)
	if err != nil {
		return nil, fmt.Errorf("failed to decode data read from file [%s]: %v\n%s", path, err, content)
	}
	f.normalizeObjectMeta(decodedObj, cleanedPath)
	return decodedObj, nil
}

func (f *fileREST) normalizeObjectMeta(obj runtime.Object, path string) {
	accessor, err := meta.Accessor(obj)
	if err != nil {
		return
	}
	if f.isNamespaced {
		accessor.SetNamespace(defaultNamespace)
	} else {
		accessor.SetNamespace("")
	}
	accessor.SetName(strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)))
}

func (f *fileREST) visitDir(dirname string, extension string, newFunc func() runtime.Object, codec runtime.Decoder, visitFunc func(string, runtime.Object)) error {
	return filepath.Walk(dirname, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(info.Name(), extension) {
			return nil
		}
		newObj, err := f.read(codec, path, newFunc)
		if err != nil {
			return fmt.Errorf("failed to load data from file [%s]: %v", path, err)
		}
		visitFunc(path, newObj)
		return nil
	})
}

func (f *fileREST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	fw := &fileWatch{
		id: uuid.New().String(),
		f:  f,
		ch: make(chan watch.Event, 10),
	}
	// On initial watch, send all the existing objects
	list, err := f.List(ctx, options)
	if err != nil {
		return nil, err
	}

	go func() {
		danger := reflect.ValueOf(list).Elem()
		items := danger.FieldByName("Items")

		for i := 0; i < items.Len(); i++ {
			fw.ch <- watch.Event{
				Type:   watch.Added,
				Object: listItemToRuntimeObject(items.Index(i)),
			}
		}
	}()

	f.fileWatchersMutex.Lock()
	f.fileWatchers[fw.id] = fw
	f.fileWatchersMutex.Unlock()

	return fw, nil
}

func (f *fileREST) predicateFunc(label labels.Selector, field fields.Selector) storage.SelectionPredicate {
	return storage.SelectionPredicate{
		Label:    label,
		Field:    field,
		GetAttrs: f.attrFunc,
	}
}

type fileWatch struct {
	f  *fileREST
	id string
	ch chan watch.Event
}

func (w *fileWatch) Stop() {
	w.f.fileWatchersMutex.Lock()
	delete(w.f.fileWatchers, w.id)
	w.f.fileWatchersMutex.Unlock()
}

func (w *fileWatch) ResultChan() <-chan watch.Event {
	return w.ch
}

// TODO: implement custom table printer optionally
// func (f *fileREST) ConvertToTable(ctx context.Context, object runtime.Object, tableOptions runtime.Object) (*metav1.Table, error) {
// 	return &metav1.Table{}, nil
// }
