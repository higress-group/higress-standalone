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
	"sort"
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
const watcherQueueSize = 1024

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
		TableConvertor:   rest.NewDefaultTableConvertor(groupResource),
		groupResource:    groupResource,
		codec:            codec,
		configClient:     configClient,
		isNamespaced:     isNamespaced,
		singularName:     singularName,
		dataIdPrefix:     strings.ToLower(groupResource.Resource),
		newFunc:          newFunc,
		newListFunc:      newListFunc,
		attrFunc:         attrFunc,
		watchers:         make(map[string]*nacosWatch, 10),
		lastValidObjects: make(map[string]runtime.Object),
		listenedConfigs:  make(map[string]vo.ConfigParam),
		encryptionKey:    dataEncryptionKey,
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

	// listRefreshMutex serializes every reconcile and every mutation of the
	// state below. Lock order is listRefreshMutex -> watchersMutex; nothing
	// may acquire listRefreshMutex while holding watchersMutex.
	listRefreshMutex   sync.Mutex
	listRefreshTicker  *time.Ticker
	listConfigListened int32

	// configItems is the raw snapshot of the last fully enumerated Nacos
	// state, keyed by group + "/" + dataId. It is only committed after a
	// complete SearchConfig pass, so a partial enumeration never masquerades
	// as deletions.
	configItems map[string]*model.ConfigItem

	// lastValidObjects holds a deep copy of the last object successfully
	// published to watchers for each key. Deletions always report this object,
	// even if the raw config was overwritten with undecodable content before
	// the delete was observed.
	lastValidObjects map[string]runtime.Object

	// listenedConfigs records listeners whose ListenConfig call succeeded, so
	// failures can be retried by later reconciles.
	listenedConfigs map[string]vo.ConfigParam

	// snapshotReady reports whether at least one reconcile completed; watch
	// bootstrap is built from that state instead of an independent list.
	snapshotReady bool

	// destroyed is set under listRefreshMutex; after it is true no reconcile
	// runs and no new watchers are accepted.
	destroyed bool
	stopCh    chan struct{}
	refreshCh chan struct{}

	watchersMutex sync.RWMutex
	watchers      map[string]*nacosWatch

	newFunc     func() runtime.Object
	newListFunc func() runtime.Object
	attrFunc    storage.AttrFunc

	encryptionKey []byte

	namesDataId string
}

func (n *nacosREST) GetSingularName() string {
	return n.singularName
}

// requestRefresh performs a non-blocking, coalescing wake of the reconcile
// loop. It is the only thing SDK callbacks are allowed to do: they must never
// touch the reconcile state or publish events directly.
func (n *nacosREST) requestRefresh() {
	if n.refreshCh == nil {
		return
	}
	select {
	case n.refreshCh <- struct{}{}:
	default:
	}
}

func (n *nacosREST) startBackgroundWatcher() {
	n.listRefreshMutex.Lock()
	defer n.listRefreshMutex.Unlock()

	if n.destroyed || n.listRefreshTicker != nil {
		return
	}

	n.refreshCh = make(chan struct{}, 1)
	n.stopCh = make(chan struct{})
	n.listRefreshTicker = time.NewTicker(time.Duration(options.NacosListRefreshIntervalSecs) * time.Second)
	// The loop owns the ticker reference: Destroy may nil out the struct
	// field concurrently, and the select must never dereference it.
	ticker := n.listRefreshTicker
	go n.backgroundLoop(ticker)
}

func (n *nacosREST) backgroundLoop(ticker *time.Ticker) {
	for {
		select {
		case <-n.stopCh:
			return
		case <-ticker.C:
			n.listRefreshTickerFunc()
		case <-n.refreshCh:
			n.listRefreshTickerFunc()
		}
	}
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
			n.requestRefresh()
		},
	})
}

// Destroy stops the reconcile loop, cancels every SDK listener and detaches
// all watchers. It is idempotent and never waits for watcher consumers; it
// must not be called while holding listRefreshMutex from outside.
func (n *nacosREST) Destroy() {
	n.listRefreshMutex.Lock()
	if n.destroyed {
		n.listRefreshMutex.Unlock()
		return
	}
	n.destroyed = true
	ticker := n.listRefreshTicker
	n.listRefreshTicker = nil
	stopCh := n.stopCh

	cancelParams := make([]vo.ConfigParam, 0, len(n.listenedConfigs)+1)
	if atomic.LoadInt32(&n.listConfigListened) == 1 {
		cancelParams = append(cancelParams, vo.ConfigParam{
			DataId: n.namesDataId,
			Group:  namesGroup,
		})
	}
	for _, param := range n.listenedConfigs {
		cancelParams = append(cancelParams, param)
	}
	n.listenedConfigs = make(map[string]vo.ConfigParam)
	atomic.StoreInt32(&n.listConfigListened, 0)

	n.watchersMutex.Lock()
	watchers := n.watchers
	n.watchers = make(map[string]*nacosWatch, 10)
	n.watchersMutex.Unlock()
	n.listRefreshMutex.Unlock()

	// Everything below happens without listRefreshMutex: closing stopCh
	// terminates the background loop and every watcher forwarder, and the
	// CancelListenConfig calls are plain SDK invocations.
	if stopCh != nil {
		close(stopCh)
	}
	if ticker != nil {
		ticker.Stop()
	}
	for _, param := range cancelParams {
		if err := n.configClient.CancelListenConfig(param); err != nil {
			klog.Errorf("failed to cancel listen config %s/%s: %v", param.Group, param.DataId, err)
		}
	}
	for _, w := range watchers {
		w.Stop()
	}
}

func (n *nacosREST) notifyWatchers(ev watch.Event) {
	n.watchersMutex.RLock()
	defer n.watchersMutex.RUnlock()
	if len(n.watchers) == 0 {
		return
	}
	accessor, _ := meta.Accessor(ev.Object)
	klog.Infof("event %s %s %s/%s count(watcher)=%d", ev.Type, ev.Object.GetObjectKind(), accessor.GetNamespace(), accessor.GetName(), len(n.watchers))
	for _, w := range n.watchers {
		w.enqueue(ev)
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
	nw := newNacosWatch(n, ns, &predicate)

	n.startBackgroundWatcher()

	// Bootstrap under listRefreshMutex so the initial snapshot and the watcher
	// registration are atomic against reconcile: the watcher observes exactly
	// "the Added events of one committed snapshot, then the increments that
	// follow its registration", never a stale Added behind a newer Deleted.
	n.listRefreshMutex.Lock()
	if n.destroyed {
		n.listRefreshMutex.Unlock()
		return nil, fmt.Errorf("storage for %s is already destroyed", n.groupResource)
	}
	if !n.snapshotReady {
		// No reconcile state yet: build it now. A failed enumeration must be
		// reported instead of returning a seemingly-complete empty stream.
		if err := n.reconcileLocked(); err != nil {
			n.listRefreshMutex.Unlock()
			return nil, err
		}
	}
	snapshot := n.snapshotEventsLocked(ns, &predicate)
	n.watchersMutex.Lock()
	n.watchers[nw.id] = nw
	n.watchersMutex.Unlock()
	n.listRefreshMutex.Unlock()

	go nw.forwardLoop(snapshot)

	return nw, nil
}

// snapshotEventsLocked builds the initial Added stream for a new watcher from
// the last committed reconcile state. Objects are filtered by namespace and
// selector and deep-copied; the snapshot bypasses the bounded incremental
// queue, so any snapshot size is delivered without self-inflicted overflow.
func (n *nacosREST) snapshotEventsLocked(ns string, predicate *storage.SelectionPredicate) []watch.Event {
	keys := make([]string, 0, len(n.lastValidObjects))
	for key := range n.lastValidObjects {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	snapshot := make([]watch.Event, 0, len(keys))
	for _, key := range keys {
		obj := n.lastValidObjects[key].DeepCopyObject()
		if !matchesWatcher(predicate, ns, obj) {
			continue
		}
		snapshot = append(snapshot, watch.Event{
			Type:   watch.Added,
			Object: obj,
		})
	}
	return snapshot
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
		klog.Infof("failed to decoded config #1: %v", err)
		return nil, err
	}
	obj, _, err := decoder.Decode([]byte(decryptedConfig), nil, newFunc())
	if err != nil {
		klog.Infof("failed to decoded config #2: %v", err)
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

// refreshConfigList runs one reconcile cycle: it enumerates the complete Nacos
// state and reconciles watchers and internal state from that single snapshot.
func (n *nacosREST) refreshConfigList() {
	n.listRefreshMutex.Lock()
	defer n.listRefreshMutex.Unlock()
	_ = n.reconcileLocked()
}

// reconcileLocked performs the deterministic reconcile order. It must be
// called with listRefreshMutex held.
//
//  1. Enumerate the complete raw state into a temporary map; on any failure
//     keep the previous objects and listeners and report the error without
//     emitting deletions.
//  2. Decode present keys. First valid object: publish Added. Changed content
//     (resourceVersion/content MD5): update and publish Modified. Identical:
//     no event.
//  3. Undecodable content never destroys the last valid object, and the key
//     still counts as present, so no premature Deleted is possible.
//  4. Keys missing from the complete snapshot: cancel the listener, publish
//     one Deleted carrying the last valid object, then drop all state for the
//     key. Keys that never decoded still get their subscription cleaned up.
//  5. Commit the raw snapshot and rewrite the names index (sorted keys, or
//     the EMPTY placeholder so removing the last resource leaves no stale
//     index).
//  6. (Re-)register listeners for every present key, so transient ListenConfig
//     failures are retried by later reconciles. Initially invalid configs are
//     listened too, so a corrected config wakes the reconcile promptly.
func (n *nacosREST) reconcileLocked() error {
	if n.destroyed {
		return errors.New("storage is destroyed")
	}

	rawItems := make(map[string]*model.ConfigItem, len(n.configItems))
	var allConfigKeys []string
	err := n.enumerateConfigs(&vo.SearchConfigParam{
		Search: "blur",
		DataId: n.dataIdPrefix + wildcardSuffix,
	}, func(item *model.ConfigItem) {
		key := item.Group + "/" + item.DataId
		allConfigKeys = append(allConfigKeys, key)
		rawItems[key] = item
	})
	if err != nil {
		// Keep the previous complete state: an incomplete enumeration must
		// never be interpreted as deletions.
		klog.Errorf("failed to enumerate %s configs, keeping previous state: %v", n.groupResource, err)
		return err
	}
	sort.Strings(allConfigKeys)

	for _, key := range allConfigKeys {
		item := rawItems[key]
		obj, err := n.decodeConfig(n.codec, item.Content, n.newFunc)
		if err != nil {
			// Do not log the config body: it may contain secrets.
			klog.Errorf("failed to decode config %s/%s: %v", item.Group, item.DataId, err)
			continue
		}
		accessor, err := meta.Accessor(obj)
		if err != nil {
			klog.Errorf("config %s/%s has no object metadata: %v", item.Group, item.DataId, err)
			continue
		}
		prev, exists := n.lastValidObjects[key]
		if !exists {
			n.lastValidObjects[key] = obj.DeepCopyObject()
			klog.Infof("%s/%s is added", item.Group, item.DataId)
			n.notifyWatchers(watch.Event{
				Type:   watch.Added,
				Object: obj,
			})
			continue
		}
		prevAccessor, err := meta.Accessor(prev)
		if err != nil {
			klog.Errorf("cached object %s has no metadata: %v", key, err)
			continue
		}
		if prevAccessor.GetResourceVersion() != accessor.GetResourceVersion() {
			n.lastValidObjects[key] = obj.DeepCopyObject()
			klog.Infof("%s/%s is changed", item.Group, item.DataId)
			n.notifyWatchers(watch.Event{
				Type:   watch.Modified,
				Object: obj,
			})
		}
	}

	oldKeys := make([]string, 0, len(n.configItems))
	for key := range n.configItems {
		oldKeys = append(oldKeys, key)
	}
	sort.Strings(oldKeys)
	for _, key := range oldKeys {
		if _, ok := rawItems[key]; ok {
			continue
		}
		item := n.configItems[key]
		// The subscription is always cleaned up, even when no valid object
		// was ever published for this key.
		n.cancelListenLocked(key)
		if prev, ok := n.lastValidObjects[key]; ok {
			klog.Infof("%s/%s is deleted", item.Group, item.DataId)
			n.notifyWatchers(watch.Event{
				Type:   watch.Deleted,
				Object: prev.DeepCopyObject(),
			})
			delete(n.lastValidObjects, key)
		} else {
			klog.Infof("%s/%s is deleted (no valid object was published)", item.Group, item.DataId)
		}
	}

	n.configItems = rawItems
	n.updateNamesIndexLocked(allConfigKeys)

	for _, key := range allConfigKeys {
		if _, listened := n.listenedConfigs[key]; listened {
			continue
		}
		item := rawItems[key]
		param := vo.ConfigParam{
			DataId: item.DataId,
			Group:  item.Group,
			OnChange: func(namespace, group, dataId, data string) {
				n.requestRefresh()
			},
		}
		if err := n.configClient.ListenConfig(param); err != nil {
			klog.Errorf("failed to listen config %s: %v", key, err)
			continue
		}
		n.listenedConfigs[key] = param
	}

	n.snapshotReady = true
	return nil
}

func (n *nacosREST) cancelListenLocked(key string) {
	param, ok := n.listenedConfigs[key]
	if !ok {
		return
	}
	delete(n.listenedConfigs, key)
	if err := n.configClient.CancelListenConfig(param); err != nil {
		klog.Errorf("failed to cancel listen config %s: %v", key, err)
	}
}

func (n *nacosREST) updateNamesIndexLocked(allConfigKeys []string) {
	var newNamesData string
	if len(allConfigKeys) > 0 {
		newNamesData = strings.Join(allConfigKeys, "\n") + "\n"
	} else {
		// Nacos does not support empty content; use the same placeholder as
		// the delete path so removing the last resource never leaves a stale
		// index behind.
		newNamesData = emptyNamesPlaceholder
	}
	namesData, err := n.readRaw(namesGroup, n.namesDataId)
	if err != nil {
		klog.Errorf("failed to read %s/%s: %v", namesGroup, n.namesDataId, err)
		return
	}
	if namesData == newNamesData || (len(allConfigKeys) == 0 && namesData == "") {
		return
	}
	if err := n.writeRaw(namesGroup, n.namesDataId, newNamesData, calculateMd5(namesData)); err != nil {
		klog.Errorf("failed to update %s/%s: %v", namesGroup, n.namesDataId, err)
	}
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

// matchesWatcher applies the namespace and selector filter of a watcher.
// Selector errors are treated as a match, matching the historical behavior of
// the apiserver storage layer.
func matchesWatcher(predicate *storage.SelectionPredicate, ns string, obj runtime.Object) bool {
	if predicate != nil {
		match, err := predicate.Matches(obj)
		if err == nil && !match {
			return false
		}
	}
	if ns != "" {
		accessor, err := meta.Accessor(obj)
		if err != nil {
			return false
		}
		if accessor.GetNamespace() != ns {
			return false
		}
	}
	return true
}

// nacosWatch is a single watch stream. Producers only ever perform non-blocking
// enqueues into the bounded incremental queue; a dedicated forwarder goroutine
// owns the result channel: it first delivers the bootstrap snapshot, then the
// queued increments, and it is the only component allowed to close the result
// channel. A full queue terminates normal delivery with a Kubernetes 410
// watch.Error so the consumer relists instead of silently missing events.
type nacosWatch struct {
	f         *nacosREST
	id        string
	ns        string
	predicate *storage.SelectionPredicate

	incremental chan watch.Event
	result      chan watch.Event

	stopOnce     sync.Once
	stopped      chan struct{}
	onceOverflow sync.Once
	overflow     chan struct{}
	terminated   atomic.Bool
}

func newNacosWatch(f *nacosREST, ns string, predicate *storage.SelectionPredicate) *nacosWatch {
	return &nacosWatch{
		f:           f,
		id:          uuid.New().String(),
		ns:          ns,
		predicate:   predicate,
		incremental: make(chan watch.Event, watcherQueueSize),
		result:      make(chan watch.Event),
		stopped:     make(chan struct{}),
		overflow:    make(chan struct{}),
	}
}

// Stop detaches the watcher and unblocks the forwarder immediately, even if
// its consumer never reads again.
func (w *nacosWatch) Stop() {
	w.stopOnce.Do(func() {
		close(w.stopped)
		w.terminated.Store(true)
	})
	w.f.watchersMutex.Lock()
	delete(w.f.watchers, w.id)
	w.f.watchersMutex.Unlock()
}

func (w *nacosWatch) ResultChan() <-chan watch.Event {
	return w.result
}

// enqueue filters and buffers one event without ever blocking the producer.
// Each event is deep-copied so watchers cannot observe each other's objects.
func (w *nacosWatch) enqueue(ev watch.Event) {
	if w.terminated.Load() {
		return
	}
	if !matchesWatcher(w.predicate, w.ns, ev.Object) {
		return
	}
	select {
	case w.incremental <- watch.Event{
		Type:   ev.Type,
		Object: ev.Object.DeepCopyObject(),
	}:
	default:
		w.onceOverflow.Do(func() {
			close(w.overflow)
		})
		w.terminated.Store(true)
		klog.Warningf("watcher %s incremental queue overflow, sending expired signal", w.id)
	}
}

func (w *nacosWatch) forwardLoop(initial []watch.Event) {
	defer close(w.result)
	for _, ev := range initial {
		select {
		case w.result <- ev:
		case <-w.stopped:
			return
		case <-w.f.stopCh:
			return
		}
	}
	for {
		// Overflow takes priority over further normal delivery.
		select {
		case <-w.overflow:
			w.sendExpired()
			return
		default:
		}
		select {
		case <-w.overflow:
			w.sendExpired()
			return
		case <-w.stopped:
			return
		case <-w.f.stopCh:
			return
		case ev, ok := <-w.incremental:
			if !ok {
				return
			}
			select {
			case w.result <- ev:
			case <-w.overflow:
				w.sendExpired()
				return
			case <-w.stopped:
				return
			case <-w.f.stopCh:
				return
			}
		}
	}
}

// sendExpired reports a Kubernetes 410 status so the consumer relists. It may
// block until the consumer observes it or the watcher/storage is stopped;
// Destroy never waits for this delivery.
func (w *nacosWatch) sendExpired() {
	status := apierrors.NewResourceExpired("too many pending watch events; relist required").Status()
	select {
	case w.result <- watch.Event{
		Type:   watch.Error,
		Object: &status,
	}:
	case <-w.stopped:
	case <-w.f.stopCh:
	}
}
