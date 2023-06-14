package registry

import (
	"bytes"
	"context"
	"crypto/md5"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
	"github.com/nacos-group/nacos-sdk-go/v2/model"
	"github.com/nacos-group/nacos-sdk-go/v2/vo"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	genericapirequest "k8s.io/apiserver/pkg/endpoints/request"
	"k8s.io/apiserver/pkg/registry/rest"
	"k8s.io/apiserver/pkg/storage"
	"k8s.io/klog/v2"
)

const dataIdSeparator = "."
const wildcardSuffix = dataIdSeparator + "*"
const searchPageSize = 50
const listRefreshInterval = 10 * time.Second

// ErrItemAlreadyExists means the item already exists.
var ErrItemAlreadyExists = fmt.Errorf("item already exists")

var _ rest.StandardStorage = &nacosREST{}
var _ rest.Scoper = &nacosREST{}
var _ rest.Storage = &nacosREST{}

// NewNacosREST instantiates a new REST storage.
func NewNacosREST(
	groupResource schema.GroupResource,
	codec runtime.Codec,
	configClient config_client.IConfigClient,
	isNamespaced bool,
	singularName string,
	newFunc func() runtime.Object,
	newListFunc func() runtime.Object,
	attrFunc storage.AttrFunc,
) rest.Storage {
	if attrFunc == nil {
		if isNamespaced {
			if isNamespaced {
				attrFunc = storage.DefaultNamespaceScopedAttr
			} else {
				attrFunc = storage.DefaultClusterScopedAttr
			}
		}
	}
	n := &nacosREST{
		TableConvertor: rest.NewDefaultTableConvertor(groupResource),
		groupResource:  groupResource,
		codec:          codec,
		configClient:   configClient,
		isNamespaced:   isNamespaced,
		singularName:   singularName,
		dataIdPrefix:   strings.ToLower(groupResource.Resource),
		newFunc:        newFunc,
		newListFunc:    newListFunc,
		attrFunc:       attrFunc,
		watchers:       make(map[int]*nacosWatch, 10),
	}
	n.startBackgroundWatcher()
	return n
}

type nacosREST struct {
	rest.TableConvertor
	groupResource schema.GroupResource
	codec         runtime.Codec
	configClient  config_client.IConfigClient
	isNamespaced  bool
	singularName  string
	dataIdPrefix  string

	listRefreshMutex  sync.Mutex
	listRefreshTicker *time.Ticker
	watchersMutex     sync.RWMutex
	watchers          map[int]*nacosWatch

	newFunc     func() runtime.Object
	newListFunc func() runtime.Object
	attrFunc    storage.AttrFunc

	configItems map[string]*model.ConfigItem
}

func (n *nacosREST) GetSingularName() string {
	return n.singularName
}

func (n *nacosREST) startBackgroundWatcher() {
	if n.listRefreshTicker != nil {
		return
	}

	n.listRefreshMutex.Lock()
	defer n.listRefreshMutex.Unlock()

	if n.listRefreshTicker != nil {
		return
	}

	n.listRefreshTicker = time.NewTicker(listRefreshInterval)
	go func(n *nacosREST) {
		for {
			<-n.listRefreshTicker.C
			n.refreshConfigList()
		}
	}(n)
}

func (n *nacosREST) Destroy() {
	n.listRefreshMutex.Lock()
	defer n.listRefreshMutex.Unlock()
	if n.listRefreshTicker != nil {
		n.listRefreshTicker.Stop()
		n.listRefreshTicker = nil
	}
}

func (n *nacosREST) notifyWatchers(ev watch.Event) {
	n.watchersMutex.RLock()
	defer n.watchersMutex.RUnlock()
	accessor, _ := meta.Accessor(ev.Object)
	klog.Info("event %s %s %s/%s count(watcher)=%d", ev.Type, ev.Object.GetObjectKind(), accessor.GetNamespace(), accessor.GetName(), len(n.watchers))
	for _, w := range n.watchers {
		w.SendEvent(ev, false)
	}
}

func (n *nacosREST) New() runtime.Object {
	return n.newFunc()
}

func (n *nacosREST) NewList() runtime.Object {
	return n.newListFunc()
}

func (n *nacosREST) NamespaceScoped() bool {
	return n.isNamespaced
}

func (n *nacosREST) Get(
	ctx context.Context,
	name string,
	options *metav1.GetOptions,
) (runtime.Object, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	obj, _, err := n.read(n.codec, ns, n.objectDataId(ctx, name), n.newFunc)
	if obj == nil && err == nil {
		requestInfo, ok := genericapirequest.RequestInfoFrom(ctx)
		var groupResource = schema.GroupResource{}
		if ok {
			groupResource.Group = requestInfo.APIGroup
			groupResource.Resource = requestInfo.Resource
		}
		klog.Warningf("%s %s/%s not found", n.groupResource, ns, name)
		return nil, apierrors.NewNotFound(groupResource, name)
	}
	klog.Infof("%s %s/%s got", n.groupResource, ns, name)
	return obj, err
}

func (n *nacosREST) List(
	ctx context.Context,
	options *metainternalversion.ListOptions,
) (runtime.Object, error) {
	newListObj := n.NewList()
	v, err := getListPrt(newListObj)
	if err != nil {
		return nil, err
	}

	ns, _ := genericapirequest.NamespaceFrom(ctx)

	searchConfigParam := vo.SearchConfigParam{
		Search:   "blur",
		DataId:   n.dataIdPrefix + wildcardSuffix,
		Group:    ns,
		PageSize: searchPageSize,
	}
	predicate := n.buildListPredicate(options)
	count := 0
	err = n.enumerateConfigs(&searchConfigParam, func(item *model.ConfigItem) {
		obj, err := n.decodeConfig(n.codec, item.Content, n.newFunc)
		if obj == nil || err != nil {
			return
		}
		if ok, err := predicate.Matches(obj); err == nil && ok {
			appendItem(v, obj)
			count++
		}
	})
	if err != nil {
		return nil, err
	}

	klog.Infof("%s %s list count=%d", n.groupResource, ns, count)
	return newListObj, nil
}

func (n *nacosREST) Create(
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

	accessor, err := meta.Accessor(obj)
	if err != nil {
		return nil, err
	}

	ns, _ := genericapirequest.NamespaceFrom(ctx)

	name := accessor.GetName()

	dataId := n.objectDataId(ctx, name)

	currentConfig, err := n.readRaw(ns, dataId)
	if currentConfig != "" && err == nil {
		return nil, apierrors.NewConflict(n.groupResource, name, ErrItemAlreadyExists)
	}

	accessor.SetCreationTimestamp(metav1.NewTime(time.Now()))
	if err := n.write(n.codec, ns, dataId, "", obj); err != nil {
		return nil, err
	}

	return obj, nil
}

func (n *nacosREST) Update(
	ctx context.Context,
	name string,
	objInfo rest.UpdatedObjectInfo,
	createValidation rest.ValidateObjectFunc,
	updateValidation rest.ValidateObjectUpdateFunc,
	forceAllowCreate bool,
	options *metav1.UpdateOptions,
) (runtime.Object, bool, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	dataId := n.objectDataId(ctx, name)

	isCreate := false
	oldObj, oldConfig, err := n.read(n.codec, ns, dataId, n.newFunc)
	if err != nil {
		return nil, false, err
	}
	if oldConfig == "" && err == nil {
		if !forceAllowCreate {
			return nil, false, err
		}
		isCreate = true
	}

	updatedObj, err := objInfo.UpdatedObject(ctx, oldObj)
	if err != nil {
		return nil, false, err
	}

	oldAccessor, err := meta.Accessor(oldObj)
	if err != nil {
		return nil, false, err
	}

	updatedAccessor, err := meta.Accessor(updatedObj)
	if err != nil {
		return nil, false, err
	}

	if isCreate {
		obj, err := n.Create(ctx, updatedObj, createValidation, nil)
		return obj, err == nil, err
	}

	if updateValidation != nil {
		if err := updateValidation(ctx, updatedObj, oldObj); err != nil {
			return nil, false, err
		}
	}

	if updatedAccessor.GetResourceVersion() != oldAccessor.GetResourceVersion() {
		return nil, false, apierrors.NewConflict(n.groupResource, name, nil)
	}

	if err := n.write(n.codec, ns, dataId, oldAccessor.GetResourceVersion(), updatedObj); err != nil {
		return nil, false, err
	}

	return updatedObj, false, nil
}

func (n *nacosREST) Delete(
	ctx context.Context,
	name string,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions) (runtime.Object, bool, error) {
	dataId := n.objectDataId(ctx, name)

	oldObj, err := n.Get(ctx, name, nil)
	if err != nil {
		return nil, false, err
	}
	if deleteValidation != nil {
		if err := deleteValidation(ctx, oldObj); err != nil {
			return nil, false, err
		}
	}

	ns, _ := genericapirequest.NamespaceFrom(ctx)
	deleted, err := n.configClient.DeleteConfig(vo.ConfigParam{
		DataId: dataId,
		Group:  ns,
	})
	if err != nil {
		return nil, false, err
	}
	if !deleted {
		return nil, false, errors.New("delete config failed: " + dataId)
	}

	return oldObj, true, nil
}

func (n *nacosREST) DeleteCollection(
	ctx context.Context,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions,
	listOptions *metainternalversion.ListOptions,
) (runtime.Object, error) {
	list, err := n.List(ctx, listOptions)
	if err != nil {
		return nil, err
	}

	deletedItems := n.NewList()
	v, err := getListPrt(deletedItems)
	if err != nil {
		return nil, err
	}

	for _, obj := range list.(*unstructured.UnstructuredList).Items {
		if deletedObj, deleted, err := n.Delete(ctx, obj.GetName(), deleteValidation, options); deleted && err == nil {
			appendItem(v, deletedObj)
		}
	}
	return deletedItems, nil
}

func (n *nacosREST) objectDataId(ctx context.Context, name string) string {
	//if n.isNamespaced {
	//	// FIXME: return error if namespace is not found
	//	ns, _ := genericapirequest.NamespaceFrom(ctx)
	//	return strings.Join([]string{n.dataIdPrefix, ns, name}, dataIdSeparator)
	//}
	return strings.Join([]string{n.dataIdPrefix, name}, dataIdSeparator)
}

func (n *nacosREST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	predicate := n.buildListPredicate(options)
	nw := &nacosWatch{
		id:        len(n.watchers),
		f:         n,
		ch:        make(chan watch.Event, 1024),
		ns:        ns,
		predicate: &predicate,
	}

	n.startBackgroundWatcher()

	// On initial watch, send all the existing objects
	list, err := n.List(ctx, options)
	if err != nil {
		return nil, err
	}

	danger := reflect.ValueOf(list).Elem()
	items := danger.FieldByName("Items")

	for i := 0; i < items.Len(); i++ {
		obj := items.Index(i).Addr().Interface().(runtime.Object)
		nw.SendEvent(watch.Event{
			Type:   watch.Added,
			Object: obj,
		}, true)
	}

	n.watchersMutex.Lock()
	defer n.watchersMutex.Unlock()
	n.watchers[nw.id] = nw

	return nw, nil
}

func (n *nacosREST) buildListPredicate(options *metainternalversion.ListOptions) storage.SelectionPredicate {
	label := labels.Everything()
	field := fields.Everything()
	if options != nil {
		if options.LabelSelector != nil {
			label = options.LabelSelector
		}
		if options.FieldSelector != nil {
			field = options.FieldSelector
		}
	}
	return storage.SelectionPredicate{
		Label:    label,
		Field:    field,
		GetAttrs: n.attrFunc,
	}
}

func (n *nacosREST) enumerateConfigs(param *vo.SearchConfigParam, action func(*model.ConfigItem)) error {
	searchConfigParam := *param
	searchConfigParam.PageNo = 1
	for {
		page, err := n.configClient.SearchConfig(searchConfigParam)
		if err != nil {
			return err
		}

		if page.PagesAvailable == 0 {
			break
		}

		for _, item := range page.PageItems {
			localItem := *(&item)
			action(&localItem)
		}

		if page.PagesAvailable <= searchConfigParam.PageNo {
			break
		}

		searchConfigParam.PageNo++
	}
	return nil
}

func (n *nacosREST) read(decoder runtime.Decoder, group, dataId string, newFunc func() runtime.Object) (runtime.Object, string, error) {
	config, err := n.readRaw(group, dataId)
	if err != nil {
		return nil, "", err
	}
	if config == "" {
		return nil, "", nil
	}
	obj, err := n.decodeConfig(decoder, config, newFunc)
	if err != nil {
		return nil, config, err
	}
	return obj, config, nil
}

func (n *nacosREST) readRaw(group, dataId string) (string, error) {
	return n.configClient.GetConfig(vo.ConfigParam{
		DataId: dataId,
		Group:  group,
	})
}

func (n *nacosREST) decodeConfig(decoder runtime.Decoder, config string, newFunc func() runtime.Object) (runtime.Object, error) {
	obj, _, err := decoder.Decode([]byte(config), nil, newFunc())
	if err != nil {
		return nil, err
	}
	accessor, err := meta.Accessor(obj)
	if err == nil {
		accessor.SetResourceVersion(calculateMd5(config))
	}
	return obj, nil
}

func (n *nacosREST) write(encoder runtime.Encoder, group, dataId, oldMd5 string, obj runtime.Object) error {
	accessor, err := meta.Accessor(obj)
	if err != nil {
		return err
	}
	// No resource version saved into nacos
	accessor.SetResourceVersion("")

	buf := new(bytes.Buffer)
	if err := encoder.Encode(obj, buf); err != nil {
		return err
	}
	content := buf.String()
	return n.writeRaw(group, dataId, content, oldMd5)
}

func (n *nacosREST) writeRaw(group, dataId, content, oldMd5 string) error {
	published, err := n.configClient.PublishConfig(vo.ConfigParam{
		DataId:  dataId,
		Group:   group,
		Content: content,
		CasMd5:  oldMd5,
	})
	if err != nil {
		return err
	} else if !published {
		return fmt.Errorf("failed to publish config %s", dataId)
	}
	return nil
}

func (n *nacosREST) refreshConfigList() {
	n.listRefreshMutex.Lock()
	defer n.listRefreshMutex.Unlock()

	configItems := map[string]*model.ConfigItem{}
	var newConfigKeys []string
	err := n.enumerateConfigs(&vo.SearchConfigParam{
		Search: "blur",
		DataId: n.dataIdPrefix + wildcardSuffix,
	}, func(item *model.ConfigItem) {
		key := item.Group + "/" + item.DataId
		if _, ok := n.configItems[key]; !ok {
			newConfigKeys = append(newConfigKeys, key)
		}
		configItems[key] = item
	})
	if err != nil {
		return
	}

	var removedConfigKeys []string
	for key, _ := range n.configItems {
		if _, ok := configItems[key]; !ok {
			removedConfigKeys = append(removedConfigKeys, key)
		}
	}

	for _, key := range newConfigKeys {
		configItem := configItems[key]
		obj, err := n.decodeConfig(n.codec, configItem.Content, n.newFunc)
		if err != nil {
			delete(configItems, key)
			continue
		}
		klog.Infof("%s/%s is added", configItem.Group, configItem.DataId)
		n.notifyWatchers(watch.Event{
			Type:   watch.Added,
			Object: obj,
		})
		err = n.configClient.ListenConfig(vo.ConfigParam{
			DataId: configItem.DataId,
			Group:  configItem.Group,
			OnChange: func(namespace, group, dataId, data string) {
				obj, err := n.decodeConfig(n.codec, data, n.newFunc)
				if err != nil {
					return
				}
				klog.Infof("%s/%s is changed", group, dataId)
				n.notifyWatchers(watch.Event{
					Type:   watch.Modified,
					Object: obj,
				})
			},
		})
		if err != nil {
			klog.Errorf("failed to listen config %s: %v", key, err)
		}
	}
	for _, key := range removedConfigKeys {
		configItem := n.configItems[key]
		obj, err := n.decodeConfig(n.codec, configItem.Content, n.newFunc)
		if err != nil {
			continue
		}
		_ = n.configClient.CancelListenConfig(vo.ConfigParam{
			DataId: configItem.DataId,
			Group:  configItem.Group,
		})
		klog.Infof("%s/%s is deleted", configItem.Group, configItem.DataId)
		n.notifyWatchers(watch.Event{
			Type:   watch.Deleted,
			Object: obj,
		})
	}
	n.configItems = configItems
}

func calculateMd5(str string) string {
	w := md5.New()
	_, _ = io.WriteString(w, str)
	return fmt.Sprintf("%x", w.Sum(nil))
}

type nacosWatch struct {
	f         *nacosREST
	id        int
	ch        chan watch.Event
	ns        string
	predicate *storage.SelectionPredicate
}

func (w *nacosWatch) Stop() {
	w.f.watchersMutex.Lock()
	defer w.f.watchersMutex.Unlock()
	delete(w.f.watchers, w.id)
}

func (w *nacosWatch) ResultChan() <-chan watch.Event {
	return w.ch
}

func (w *nacosWatch) SendEvent(ev watch.Event, force bool) bool {
	if !force {
		if w.predicate != nil {
			match, err := w.predicate.Matches(ev.Object)
			if err == nil && !match {
				// If something went wrong, we assume it's a match
				return false
			}
		}
		if ns := w.ns; ns != "" {
			accessor, err := meta.Accessor(ev.Object)
			if err != nil {
				return false
			}
			if accessor.GetNamespace() != ns {
				return false
			}
		}
	}
	w.ch <- ev
	return true
}

// TODO: implement custom table printer optionally
// func (n *nacosREST) ConvertToTable(ctx context.Context, object runtime.Object, tableOptions runtime.Object) (*metav1.Table, error) {
// 	return &metav1.Table{}, nil
// }
