package registry

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alibaba/higress/api-server/pkg/options"
	"github.com/alibaba/higress/api-server/pkg/utils"
	"github.com/google/uuid"
	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
	"github.com/nacos-group/nacos-sdk-go/v2/common/constant"
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
const encryptionMark = "enc|"
const namesSuffix = "__names__"
const namesGroup = constant.DEFAULT_GROUP
const emptyNamesPlaceholder = "EMPTY"
const defaultNacosCacheSyncDelay time.Duration = 500 * time.Millisecond

var (
	nacosCacheSyncDelay = defaultNacosCacheSyncDelay
)

func init() {
	// Read nacosCacheSyncDelay from environment variable NACOS_CACHE_SYNC_DELAY
	if delayStr := os.Getenv("NACOS_CACHE_SYNC_DELAY"); delayStr != "" {
		if delay, err := time.ParseDuration(delayStr); err == nil {
			nacosCacheSyncDelay = delay
		} else {
			klog.Errorf("failed to parse NACOS_CACHE_SYNC_DELAY: %v, using default value %v", err, nacosCacheSyncDelay)
		}
	}
	klog.Infof("NacosCacheSyncDelay: %v", nacosCacheSyncDelay)
}

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
	dataEncryptionKey []byte,
) REST {
	if attrFunc == nil {
		if isNamespaced {
			attrFunc = storage.DefaultNamespaceScopedAttr
		} else {
			attrFunc = storage.DefaultClusterScopedAttr
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
		watchers:       make(map[string]*nacosWatch, 10),
		encryptionKey:  dataEncryptionKey,
	}
	n.namesDataId = n.dataIdPrefix + dataIdSeparator + namesSuffix
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

	listRefreshMutex   sync.Mutex
	listRefreshTicker  *time.Ticker
	listConfigListened int32
	watchersMutex      sync.RWMutex
	watchers           map[string]*nacosWatch

	newFunc     func() runtime.Object
	newListFunc func() runtime.Object
	attrFunc    storage.AttrFunc

	encryptionKey []byte

	namesDataId string
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

	n.listRefreshTicker = time.NewTicker(time.Duration(options.NacosListRefreshIntervalSecs) * time.Second)
	go func(n *nacosREST) {
		for {
			<-n.listRefreshTicker.C
			n.listRefreshTickerFunc()
		}
	}(n)
}

func (n *nacosREST) listRefreshTickerFunc() {
	if atomic.LoadInt32(&n.listConfigListened) == 0 {
		if err := n.watchNamesConfig(); err == nil {
			atomic.StoreInt32(&n.listConfigListened, 1)
		} else {
			klog.Errorf("failed to watch names config: %v", err)
		}
	}

	n.refreshConfigList()
}

func (n *nacosREST) watchNamesConfig() error {
	return n.configClient.ListenConfig(vo.ConfigParam{
		DataId: n.namesDataId,
		Group:  namesGroup,
		OnChange: func(namespace, group, dataId, data string) {
			n.refreshConfigList()
		},
	})
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
	klog.Infof("event %s %s %s/%s count(watcher)=%d", ev.Type, ev.Object.GetObjectKind(), accessor.GetNamespace(), accessor.GetName(), len(n.watchers))
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
	klog.Infof("[%s] %s/%s got", n.groupResource, ns, name)
	if err == nil {
		return obj, nil
	}
	return obj, apierrors.NewInternalError(err)
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
		Search: "blur",
		DataId: n.dataIdPrefix + wildcardSuffix,
		Group:  ns,
	}
	predicate := n.buildListPredicate(options)
	count := 0
	err = n.enumerateConfigs(&searchConfigParam, func(item *model.ConfigItem) {
		obj, err := n.decodeConfig(n.codec, item.Content, n.newFunc)
		if obj == nil || err != nil {
			klog.Errorf("failed to decode config [#3] %s/%s: %v", item.Group, item.DataId, err)
			return
		}
		if ok, err := predicate.Matches(obj); err == nil && ok {
			appendItem(v, obj)
			count++
		}
	})
	if err != nil {
		return nil, apierrors.NewInternalError(err)
	}

	klog.Infof("[%s] %s list count=%d", n.groupResource, ns, count)
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
			return nil, apierrors.NewInternalError(err)
		}
	}

	accessor, err := meta.Accessor(obj)
	if err != nil {
		return nil, apierrors.NewInternalError(err)
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
		return nil, apierrors.NewInternalError(err)
	}

	nameKey := ns + "/" + name
	namesData, err := n.readRaw(namesGroup, n.namesDataId)
	if err != nil {
		klog.Errorf("failed to read %s/%s: %v", namesGroup, n.namesDataId, err)
	} else {
		newNamesData := namesData + nameKey + "\n"
		err := n.writeRaw(namesGroup, n.namesDataId, newNamesData, calculateMd5(namesData))
		if err != nil {
			klog.Errorf("failed to update %s/%s: %v", namesGroup, n.namesDataId, err)
		}
	}

	n.waitForCacheSync()

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
		return nil, false, apierrors.NewInternalError(err)
	}
	if oldConfig == "" {
		if !forceAllowCreate {
			return nil, false, apierrors.NewNotFound(n.groupResource, name)
		}
		isCreate = true
	}

	updatedObj, err := objInfo.UpdatedObject(ctx, oldObj)
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}

	oldAccessor, err := meta.Accessor(oldObj)
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}

	updatedAccessor, err := meta.Accessor(updatedObj)
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}

	if isCreate {
		obj, err := n.Create(ctx, updatedObj, createValidation, nil)
		return obj, err == nil, apierrors.NewInternalError(err)
	}

	if updateValidation != nil {
		if err := updateValidation(ctx, updatedObj, oldObj); err != nil {
			return nil, false, apierrors.NewInternalError(err)
		}
	}

	if updatedAccessor.GetResourceVersion() != "" && updatedAccessor.GetResourceVersion() != oldAccessor.GetResourceVersion() {
		return nil, false, apierrors.NewConflict(n.groupResource, name, nil)
	}

	if err := n.write(n.codec, ns, dataId, oldAccessor.GetResourceVersion(), updatedObj); err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}

	n.waitForCacheSync()

	return updatedObj, false, nil
}

func (n *nacosREST) doDelete(
	ctx context.Context,
	name string,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions,
	waitForCacheSync bool) (runtime.Object, bool, error) {
	dataId := n.objectDataId(ctx, name)

	oldObj, err := n.Get(ctx, name, nil)
	if err != nil {
		return nil, false, err
	}
	if deleteValidation != nil {
		if err := deleteValidation(ctx, oldObj); err != nil {
			return nil, false, apierrors.NewBadRequest(err.Error())
		}
	}

	ns, _ := genericapirequest.NamespaceFrom(ctx)
	deleted, err := n.configClient.DeleteConfig(vo.ConfigParam{
		DataId: dataId,
		Group:  ns,
	})
	if err != nil {
		return nil, false, apierrors.NewInternalError(err)
	}
	if !deleted {
		return nil, false, errors.New("delete config failed: " + dataId)
	}

	nameKey := ns + "/" + name
	namesData, err := n.readRaw(namesGroup, n.namesDataId)
	if err != nil {
		klog.Errorf("failed to read %s/%s: %v", namesGroup, n.namesDataId, err)
	} else {
		newNamesData := strings.Replace(namesData, nameKey+"\n", "", -1)
		if newNamesData == "" {
			// Use a placeholder since Nacos does not support empty content
			newNamesData = emptyNamesPlaceholder
		}
		err := n.writeRaw(namesGroup, n.namesDataId, newNamesData, calculateMd5(namesData))
		if err != nil {
			klog.Errorf("failed to update %s/%s: %v", namesGroup, n.namesDataId, err)
		}
	}

	if waitForCacheSync {
		n.waitForCacheSync()
	}

	return oldObj, true, nil
}

func (n *nacosREST) Delete(
	ctx context.Context,
	name string,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions) (runtime.Object, bool, error) {
	return n.doDelete(ctx, name, deleteValidation, options, true)
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
		return nil, apierrors.NewInternalError(err)
	}

	for _, obj := range list.(*unstructured.UnstructuredList).Items {
		if deletedObj, deleted, err := n.doDelete(ctx, obj.GetName(), deleteValidation, options, false); deleted && err == nil {
			appendItem(v, deletedObj)
		}
	}
	return deletedItems, nil
}

func (n *nacosREST) objectDataId(ctx context.Context, name string) string {
	return strings.Join([]string{n.dataIdPrefix, name}, dataIdSeparator)
}

func (n *nacosREST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	predicate := n.buildListPredicate(options)
	nw := &nacosWatch{
		id:        uuid.New().String(),
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

	go func() {
		danger := reflect.ValueOf(list).Elem()
		items := danger.FieldByName("Items")

		for i := 0; i < items.Len(); i++ {
			nw.SendEvent(watch.Event{
				Type:   watch.Added,
				Object: listItemToRuntimeObject(items.Index(i)),
			}, true)
		}
	}()

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
	if searchConfigParam.PageSize < options.NacosConfigSearchPageSize {
		searchConfigParam.PageSize = options.NacosConfigSearchPageSize
	}
	for {
		page, err := n.configClient.SearchConfig(searchConfigParam)
		if err != nil {
			return err
		}

		if page.PagesAvailable == 0 {
			break
		}

		for _, item := range page.PageItems {
			if item.Group == namesGroup && item.DataId == n.namesDataId {
				continue
			}
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
		klog.Errorf("failed to decode config #4 %s: %v", dataId, err)
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
	decryptedConfig, err := n.decryptConfig(config)
	if err != nil {
		klog.Infof("failed to decoded config #1: %v\n%s", err, config)
		return nil, err
	}
	obj, _, err := decoder.Decode([]byte(decryptedConfig), nil, newFunc())
	if err != nil {
		klog.Infof("failed to decoded config #2: %v\n%s", err, config)
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
	oldResourceVersion := accessor.GetResourceVersion()
	// No resource version saved into nacos
	accessor.SetResourceVersion("")

	buf := new(bytes.Buffer)
	if err := encoder.Encode(obj, buf); err != nil {
		return err
	}
	content, err := n.encryptConfig(buf.String())
	if err != nil {
		return err
	}
	err = n.writeRaw(group, dataId, content, oldMd5)
	if err == nil {
		accessor.SetResourceVersion(calculateMd5(content))
	} else {
		accessor.SetResourceVersion(oldResourceVersion)
	}
	return err
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
	var allConfigKeys, newConfigKeys []string
	err := n.enumerateConfigs(&vo.SearchConfigParam{
		Search: "blur",
		DataId: n.dataIdPrefix + wildcardSuffix,
	}, func(item *model.ConfigItem) {
		key := item.Group + "/" + item.DataId
		allConfigKeys = append(allConfigKeys, key)
		if _, ok := n.configItems[key]; !ok {
			newConfigKeys = append(newConfigKeys, key)
		}
		configItems[key] = item
	})
	if err != nil {
		return
	}

	namesData, err := n.readRaw(namesGroup, n.namesDataId)
	if err != nil {
		klog.Errorf("failed to read %s/%s: %v", namesGroup, n.namesDataId, err)
	} else if len(allConfigKeys) > 0 {
		newNamesData := strings.Join(allConfigKeys, "\n") + "\n"
		if namesData != newNamesData {
			err := n.writeRaw(namesGroup, n.namesDataId, newNamesData, calculateMd5(namesData))
			if err != nil {
				klog.Errorf("failed to update %s/%s: %v", namesGroup, n.namesDataId, err)
			}
		}
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
			klog.Errorf("failed to decode config #5 %s: %v", configItem.DataId, err)
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
					klog.Errorf("failed to decode config #6 %s: %v", dataId, err)
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
			klog.Errorf("failed to decode config #7 %s: %v", configItem.DataId, err)
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

func (n *nacosREST) encryptConfig(config string) (string, error) {
	if n.encryptionKey == nil {
		return config, nil
	}

	encryptedKeyData, err := utils.AesEncrypt([]byte(config), n.encryptionKey)
	if err != nil {
		return "", err
	}
	return encryptionMark + base64.URLEncoding.EncodeToString(encryptedKeyData), nil
}

func (n *nacosREST) decryptConfig(config string) (string, error) {
	if !strings.HasPrefix(config, encryptionMark) {
		return config, nil
	}
	if n.encryptionKey == nil {
		return "", errors.New("config data is encrypted, but no data encryption key is provided")
	}
	encryptedData, err := base64.URLEncoding.DecodeString(strings.TrimPrefix(config, encryptionMark))
	if err != nil {
		return "", err
	}
	decryptedData, err := utils.AesDecrypt(encryptedData, n.encryptionKey)
	if err != nil {
		return "", err
	}
	return string(decryptedData), nil
}

func (n *nacosREST) waitForCacheSync() {
	if nacosCacheSyncDelay <= 0 {
		return
	}
	time.Sleep(nacosCacheSyncDelay)
}

func calculateMd5(str string) string {
	w := md5.New()
	_, _ = io.WriteString(w, str)
	return fmt.Sprintf("%x", w.Sum(nil))
}

type nacosWatch struct {
	f         *nacosREST
	id        string
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
