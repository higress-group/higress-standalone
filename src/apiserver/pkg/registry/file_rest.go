package registry

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"k8s.io/klog/v2"
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

	"github.com/alibaba/higress/api-server/pkg/utils"
	"github.com/fsnotify/fsnotify"
)

// ErrFileNotExists means the file doesn't actually exist.
var ErrFileNotExists = fmt.Errorf("file doesn't exist")

const fileChangeProcessInterval = 100 * time.Millisecond
const fileChangeProcessDelay = 250 * time.Millisecond
const defaultNamespace = "higress-system"

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
			if isNamespaced {
				attrFunc = storage.DefaultNamespaceScopedAttr
			} else {
				attrFunc = storage.DefaultClusterScopedAttr
			}
		}
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
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
		fileWatchers:   make(map[int]*fileWatch, 10),
	}
	err = f.startDirWatcher()
	if err != nil {
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
	fileWatchers            map[int]*fileWatch
	fileWatchersMutex       sync.RWMutex

	newFunc     func() runtime.Object
	newListFunc func() runtime.Object
	attrFunc    storage.AttrFunc
}

func (f *fileREST) GetSingularName() string {
	return f.singularName
}

func (f *fileREST) Destroy() {
	_ = f.dirWatcher.Close()
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
				klog.Errorf("error received from watcher: ", err)
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
	return obj, err
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
		return nil, err
	}

	count := 0
	if err := f.visitDir(f.objRootPath, f.objExtension, f.newFunc, f.codec, func(path string, obj runtime.Object) {
		if ok, err := predicate.Matches(obj); err == nil && ok {
			count++
			appendItem(v, obj)
		}
	}); err != nil {
		return newListObj, nil
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
			return nil, err
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
		return nil, err
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
		return nil, err
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
		return nil, false, err
	}
	filename := f.objectFileName(ctx, name)

	oldAccessor, err := meta.Accessor(oldObj)
	if err != nil {
		return nil, false, err
	}

	updatedAccessor, err := meta.Accessor(updatedObj)
	if err != nil {
		return nil, false, err
	}

	if isCreate {
		if createValidation != nil {
			if err := createValidation(ctx, updatedObj); err != nil {
				return nil, false, err
			}
		}

		updatedAccessor.SetCreationTimestamp(metav1.NewTime(time.Now()))
		updatedAccessor.SetResourceVersion("1")

		if err := f.write(f.codec, filename, updatedObj); err != nil {
			return nil, false, err
		}
		f.notifyWatchers(watch.Event{
			Type:   watch.Added,
			Object: updatedObj,
		})
		return updatedObj, true, nil
	}

	if updateValidation != nil {
		if err := updateValidation(ctx, updatedObj, oldObj); err != nil {
			return nil, false, err
		}
	}

	if updatedAccessor.GetResourceVersion() != oldAccessor.GetResourceVersion() {
		requestInfo, ok := genericapirequest.RequestInfoFrom(ctx)
		var groupResource = schema.GroupResource{}
		if ok {
			groupResource.Group = requestInfo.APIGroup
			groupResource.Resource = requestInfo.Resource
		}
		return nil, false, apierrors.NewConflict(groupResource, name, nil)
	}

	currentResourceVersion := updatedAccessor.GetResourceVersion()
	var newResourceVersion uint64
	if currentResourceVersion == "" {
		newResourceVersion = 1
	} else {
		newResourceVersion, err = strconv.ParseUint(currentResourceVersion, 10, 64)
		if err != nil {
			return nil, false, err
		}
		newResourceVersion++
	}
	updatedAccessor.SetResourceVersion(strconv.FormatUint(newResourceVersion, 10))

	if err := f.write(f.codec, filename, updatedObj); err != nil {
		return nil, false, err
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
		return nil, false, ErrFileNotExists
	}

	oldObj, err := f.Get(ctx, name, nil)
	if err != nil {
		return nil, false, err
	}
	if deleteValidation != nil {
		if err := deleteValidation(ctx, oldObj); err != nil {
			return nil, false, err
		}
	}

	if err := os.Remove(filename); err != nil {
		return nil, false, err
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
		return nil, err
	}
	if err := f.visitDir(f.objRootPath, f.objExtension, f.newFunc, f.codec, func(path string, obj runtime.Object) {
		_ = os.Remove(path)
		appendItem(v, obj)
	}); err != nil {
		return nil, fmt.Errorf("failed walking filepath %v", f.objRootPath)
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
	return os.WriteFile(filepath, buf.Bytes(), 0600)
}

func (f *fileREST) read(decoder runtime.Decoder, path string, newFunc func() runtime.Object) (runtime.Object, error) {
	cleanedPath := filepath.Clean(path)
	if _, err := os.Stat(cleanedPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		} else {
			return nil, err
		}
	}
	content, err := os.ReadFile(cleanedPath)
	if err != nil {
		return nil, err
	}
	newObj := newFunc()
	decodedObj, _, err := decoder.Decode(content, nil, newObj)
	if err != nil {
		return nil, err
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
			return err
		}
		visitFunc(path, newObj)
		return nil
	})
}

func (f *fileREST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	fw := &fileWatch{
		id: len(f.fileWatchers),
		f:  f,
		ch: make(chan watch.Event, 10),
	}
	// On initial watch, send all the existing objects
	list, err := f.List(ctx, options)
	if err != nil {
		return nil, err
	}

	danger := reflect.ValueOf(list).Elem()
	items := danger.FieldByName("Items")

	for i := 0; i < items.Len(); i++ {
		obj := items.Index(i).Addr().Interface().(runtime.Object)
		fw.ch <- watch.Event{
			Type:   watch.Added,
			Object: obj,
		}
	}

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
	id int
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
