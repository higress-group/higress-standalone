package registry

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
	"github.com/nacos-group/nacos-sdk-go/v2/model"
	"github.com/nacos-group/nacos-sdk-go/v2/vo"

	"github.com/alibaba/higress/api-server/pkg/options"

	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/apimachinery/pkg/types"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/apimachinery/pkg/watch"
	genericapirequest "k8s.io/apiserver/pkg/endpoints/request"
)

// These tests pin down the Nacos REST storage behavior contract for
// higress-group/higress#4538: deleting a Nacos resource must always clean up
// its last valid downstream object, even when the raw config was overwritten
// with invalid content before the deletion, and watch bootstrap must be
// ordered atomically against reconcile.
//
// The suite is written against the public surface of nacosREST only, so it
// compiles against both the baseline and the fixed implementation. The
// baseline is expected to fail:
//
//   - TestInvalidUpdateThenDeleteStillDeletesLastValidObject (lost Deleted)
//   - TestModifiedThenDeletedStreamIsConsistent (Deleted with stale object)
//   - TestWatchNeverResurrectsDeletedObject (stale watch bootstrap)
//   - TestListenerRetryAfterInitialFailure (no listen retry)
//   - TestSyncListenerCallbackDoesNotDuplicateEvents (callback publishes)
//   - TestDestroyIsIdempotentAndIgnoresLateCallbacks (leaked listeners)
//   - TestOverflowQueueSendsExpiredAndKeepsReconcileLive (blocking backpressure)

const testWaitTimeout = 5 * time.Second
const testSettleTimeout = 700 * time.Millisecond

var (
	testCodecOnce sync.Once
	testCodec     runtime.Codec
)

func mustTestCodec() runtime.Codec {
	testCodecOnce.Do(func() {
		scheme := runtime.NewScheme()
		utilruntime.Must(networkingv1.AddToScheme(scheme))
		testCodec = serializer.NewCodecFactory(scheme).LegacyCodec(networkingv1.SchemeGroupVersion)
	})
	return testCodec
}

// fakeConfigClient implements the subset of config_client.IConfigClient the
// registry exercises. It embeds the interface so any method invoked without
// an implementation below fails loudly instead of silently no-oping.
type fakeConfigClient struct {
	config_client.IConfigClient

	mu        sync.Mutex
	configs   map[string]string
	listeners map[string]vo.ConfigParam

	listenErrs map[string]error

	// searchErrPage makes SearchConfig return searchErr when asked for that
	// page number (0 disables the failure).
	searchErrPage int
	searchErr     error

	// onSearch, when set, is invoked exactly once inside SearchConfig after
	// the returned page has already been computed from a snapshot of the
	// current state. This models the stale-read window deterministically:
	// mutations performed by the hook are invisible to the in-flight page.
	onSearch  func()
	hookFired bool

	// onListenSync, when set, is invoked once right after the first
	// ListenConfig registration, before ListenConfig returns. It simulates an
	// SDK that fires the change callback synchronously.
	onListenSync func(param vo.ConfigParam)

	publishCalls int
	deleteCalls  int
	listenCalls  int
	cancelCalls  int
	cancelLog    []string
}

func newFakeConfigClient() *fakeConfigClient {
	return &fakeConfigClient{
		configs:    map[string]string{},
		listeners:  map[string]vo.ConfigParam{},
		listenErrs: map[string]error{},
	}
}

func configKey(group, dataId string) string {
	return group + "/" + dataId
}

func (f *fakeConfigClient) GetConfig(param vo.ConfigParam) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.configs[configKey(param.Group, param.DataId)], nil
}

func (f *fakeConfigClient) PublishConfig(param vo.ConfigParam) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.configs[configKey(param.Group, param.DataId)] = param.Content
	f.publishCalls++
	return true, nil
}

func (f *fakeConfigClient) DeleteConfig(param vo.ConfigParam) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.configs, configKey(param.Group, param.DataId))
	f.deleteCalls++
	return true, nil
}

func (f *fakeConfigClient) ListenConfig(param vo.ConfigParam) error {
	f.mu.Lock()
	key := configKey(param.Group, param.DataId)
	if err := f.listenErrs[key]; err != nil {
		f.mu.Unlock()
		return err
	}
	f.listeners[key] = param
	f.listenCalls++
	syncHook := f.onListenSync
	f.onListenSync = nil
	f.mu.Unlock()

	if syncHook != nil {
		syncHook(param)
	}
	return nil
}

func (f *fakeConfigClient) CancelListenConfig(param vo.ConfigParam) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := configKey(param.Group, param.DataId)
	if _, ok := f.listeners[key]; !ok {
		return nil
	}
	delete(f.listeners, key)
	f.cancelCalls++
	f.cancelLog = append(f.cancelLog, key)
	return nil
}

func (f *fakeConfigClient) SearchConfig(param vo.SearchConfigParam) (*model.ConfigPage, error) {
	f.mu.Lock()
	hook := f.onSearch
	if hook != nil {
		f.onSearch = nil
		f.hookFired = true
	}
	if param.Search != "blur" || !strings.HasSuffix(param.DataId, wildcardSuffix) {
		f.mu.Unlock()
		return nil, fmt.Errorf("unexpected search param: %+v", param)
	}
	prefix := strings.TrimSuffix(param.DataId, wildcardSuffix)

	var keys []string
	for key := range f.configs {
		sep := strings.Index(key, "/")
		group, dataId := key[:sep], key[sep+1:]
		if param.Group != "" && group != param.Group {
			continue
		}
		if !strings.HasPrefix(dataId, prefix) {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)

	pageSize := param.PageSize
	if pageSize <= 0 {
		pageSize = 10
	}
	pages := 0
	if len(keys) > 0 {
		pages = (len(keys) + pageSize - 1) / pageSize
	}
	pageNo := param.PageNo
	if pageNo <= 0 {
		pageNo = 1
	}

	if f.searchErrPage > 0 && pageNo == f.searchErrPage {
		err := f.searchErr
		f.mu.Unlock()
		return nil, err
	}

	var items []model.ConfigItem
	if pages > 0 && pageNo <= pages {
		start := (pageNo - 1) * pageSize
		end := start + pageSize
		if end > len(keys) {
			end = len(keys)
		}
		for _, key := range keys[start:end] {
			sep := strings.Index(key, "/")
			items = append(items, model.ConfigItem{
				Group:   key[:sep],
				DataId:  key[sep+1:],
				Content: f.configs[key],
			})
		}
	}
	f.mu.Unlock()

	// The hook runs after the page snapshot was taken and without the fake
	// lock, so it may mutate configs or drive a full reconcile (which nests
	// into SearchConfig itself, with the hook already cleared).
	if hook != nil {
		hook()
	}
	if items == nil {
		items = []model.ConfigItem{}
	}
	return &model.ConfigPage{
		TotalCount:     len(keys),
		PageNumber:     pageNo,
		PagesAvailable: pages,
		PageItems:      items,
	}, nil
}

func (f *fakeConfigClient) setContent(t *testing.T, group, dataId, content string) {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	f.configs[configKey(group, dataId)] = content
}

func (f *fakeConfigClient) removeConfig(t *testing.T, group, dataId string) {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.configs, configKey(group, dataId))
}

func (f *fakeConfigClient) hasListener(group, dataId string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	_, ok := f.listeners[configKey(group, dataId)]
	return ok
}

func (f *fakeConfigClient) listenerCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.listeners)
}

func (f *fakeConfigClient) cancelCountFor(group, dataId string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := configKey(group, dataId)
	count := 0
	for _, canceled := range f.cancelLog {
		if canceled == key {
			count++
		}
	}
	return count
}

// fireChange delivers a change callback through the currently registered
// listener, the way the real SDK would. It reports false when no listener is
// registered for the key.
func (f *fakeConfigClient) fireChange(group, dataId, content string) bool {
	f.mu.Lock()
	param, ok := f.listeners[configKey(group, dataId)]
	f.mu.Unlock()
	if !ok {
		return false
	}
	param.OnChange("", group, dataId, content)
	return true
}

func newTestIngressREST(t *testing.T) (*nacosREST, *fakeConfigClient) {
	t.Helper()
	client := newFakeConfigClient()
	storage, ok := NewNacosREST(
		schema.GroupResource{Group: networkingv1.SchemeGroupVersion.Group, Resource: "ingresses"},
		mustTestCodec(),
		client,
		true,
		"ingress",
		func() runtime.Object { return &networkingv1.Ingress{} },
		func() runtime.Object { return &networkingv1.IngressList{} },
		nil,
		nil,
	).(*nacosREST)
	if !ok {
		t.Fatalf("NewNacosREST did not return *nacosREST")
	}
	t.Cleanup(storage.Destroy)
	return storage, client
}

func makeIngress(namespace, name, uid string, ingLabels map[string]string) *networkingv1.Ingress {
	return &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:       namespace,
			Name:            name,
			UID:             types.UID(uid),
			Labels:          ingLabels,
			ResourceVersion: "1",
		},
		Spec: networkingv1.IngressSpec{
			Rules: []networkingv1.IngressRule{{Host: name + ".example.com"}},
		},
	}
}

func encodeIngress(t *testing.T, obj *networkingv1.Ingress) string {
	t.Helper()
	buf := bytes.NewBuffer(nil)
	if err := mustTestCodec().Encode(obj, buf); err != nil {
		t.Fatalf("failed to encode ingress: %v", err)
	}
	return buf.String()
}

// refreshBlocking drives one full reconcile on the test goroutine. A watchdog
// turns a reconcile that blocks on watcher backpressure into a test failure
// instead of a hang.
func refreshBlocking(t *testing.T, n *nacosREST) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		n.refreshConfigList()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(testWaitTimeout):
		t.Fatalf("refreshConfigList blocked, watcher backpressure is not bounded")
	}
}

type watchCollector struct {
	watch watch.Interface
	ch    <-chan watch.Event
}

func mustWatch(t *testing.T, n *nacosREST, ctx context.Context, listOptions *metainternalversion.ListOptions) *watchCollector {
	t.Helper()
	if ctx == nil {
		ctx = context.Background()
	}
	w, err := n.Watch(ctx, listOptions)
	if err != nil {
		t.Fatalf("Watch failed: %v", err)
	}
	c := &watchCollector{watch: w, ch: w.ResultChan()}
	t.Cleanup(w.Stop)
	return c
}

func (c *watchCollector) collect(t *testing.T, want int) []watch.Event {
	t.Helper()
	var got []watch.Event
	deadline := time.After(testWaitTimeout)
	for len(got) < want {
		select {
		case ev, ok := <-c.ch:
			if !ok {
				t.Fatalf("watch channel closed after %d events, wanted %d", len(got), want)
			}
			got = append(got, ev)
		case <-deadline:
			t.Fatalf("timed out waiting for %d events, got %d: %s", want, len(got), describeEvents(got))
		}
	}
	return got
}

// drainUntilSettled collects events until the channel stays quiet for the
// settle duration. It is only used to terminate an open-ended stream whose
// final shape is defined by the contract; pass/fail assertions never depend on
// timing races, only on the aggregated stream.
func (c *watchCollector) drainUntilSettled(t *testing.T, settle time.Duration) []watch.Event {
	t.Helper()
	var got []watch.Event
	for {
		select {
		case ev, ok := <-c.ch:
			if !ok {
				return got
			}
			got = append(got, ev)
		case <-time.After(settle):
			return got
		}
	}
}

func assertNoMoreEvents(t *testing.T, c *watchCollector) {
	t.Helper()
	select {
	case ev, ok := <-c.ch:
		if ok {
			t.Fatalf("unexpected extra event: %s", describeEvents([]watch.Event{ev}))
		}
		t.Fatal("watch channel closed unexpectedly")
	case <-time.After(testSettleTimeout):
	}
}

func waitForWatcherCount(t *testing.T, n *nacosREST, want int) {
	t.Helper()
	deadline := time.Now().Add(testWaitTimeout)
	for {
		n.watchersMutex.RLock()
		got := len(n.watchers)
		n.watchersMutex.RUnlock()
		if got >= want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %d registered watchers, have %d", want, got)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func objectIdentity(t *testing.T, obj runtime.Object) (namespace, name string, uid types.UID, ingLabels map[string]string) {
	t.Helper()
	accessor, err := meta.Accessor(obj)
	if err != nil {
		t.Fatalf("event object %T has no metadata: %v", obj, err)
	}
	return accessor.GetNamespace(), accessor.GetName(), accessor.GetUID(), accessor.GetLabels()
}

func assertEventObject(t *testing.T, ev watch.Event, wantType watch.EventType, want *networkingv1.Ingress) {
	t.Helper()
	if ev.Type != wantType {
		t.Fatalf("expected %s event, got %s: %s", wantType, ev.Type, describeEvents([]watch.Event{ev}))
	}
	ns, name, uid, ingLabels := objectIdentity(t, ev.Object)
	wantUID := want.GetUID()
	if ns != want.Namespace || name != want.Name || uid != wantUID {
		t.Fatalf("event object %s/%s(uid=%s) does not match expected %s/%s(uid=%s)",
			ns, name, uid, want.Namespace, want.Name, wantUID)
	}
	if want.GetLabels() != nil {
		for k, v := range want.GetLabels() {
			if ingLabels[k] != v {
				t.Fatalf("event object labels %v lost label %s=%s", ingLabels, k, v)
			}
		}
	}
}

func describeEvents(events []watch.Event) string {
	if len(events) == 0 {
		return "<no events>"
	}
	var parts []string
	for _, ev := range events {
		if ev.Type == watch.Error {
			parts = append(parts, fmt.Sprintf("%s(%T)", ev.Type, ev.Object))
			continue
		}
		accessor, err := meta.Accessor(ev.Object)
		if err != nil {
			parts = append(parts, fmt.Sprintf("%s(<%T>)", ev.Type, ev.Object))
			continue
		}
		parts = append(parts, fmt.Sprintf("%s(%s/%s uid=%s)", ev.Type,
			accessor.GetNamespace(), accessor.GetName(), accessor.GetUID()))
	}
	return strings.Join(parts, " -> ")
}

func ingressDataId(name string) string {
	return "ingresses" + dataIdSeparator + name
}

// ---------------------------------------------------------------------------
// Contract 1: valid A -> delete: Added(A), Deleted(A).
// ---------------------------------------------------------------------------

func TestCleanDeleteEmitsDeletedForLastValidObject(t *testing.T) {
	n, client := newTestIngressREST(t)
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, "higress-system", ingressDataId("canary-test"), encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)

	client.removeConfig(t, "higress-system", ingressDataId("canary-test"))
	refreshBlocking(t, n)

	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, a)
	assertNoMoreEvents(t, w)
	if client.hasListener("higress-system", ingressDataId("canary-test")) {
		t.Fatalf("listener for deleted resource was not canceled")
	}
	if client.cancelCountFor("higress-system", ingressDataId("canary-test")) != 1 {
		t.Fatalf("expected exactly one CancelListenConfig for the deleted resource")
	}
}

// ---------------------------------------------------------------------------
// Contract 2 (the #4538 repro): valid A -> invalid x -> delete. The invalid
// overwrite must not destroy the last valid object, and the deletion must
// still emit Deleted(A) and cancel the listener.
// ---------------------------------------------------------------------------

func TestInvalidUpdateThenDeleteStillDeletesLastValidObject(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", map[string]string{"app": "canary"})

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)

	client.setContent(t, group, dataId, "x")
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)

	// Baseline red light: no Deleted event is ever produced because the
	// cached raw content was overwritten with "x" and fails to decode.
	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, a)
	assertNoMoreEvents(t, w)
	if client.hasListener(group, dataId) {
		t.Fatalf("listener survived the deletion of the resource")
	}
	if client.cancelCountFor(group, dataId) != 1 {
		t.Fatalf("expected the deletion to cancel the resource listener")
	}
}

// ---------------------------------------------------------------------------
// Contract 3: valid A -> valid B -> delete. Whenever the watcher observed
// Modified(B), the deletion must report Deleted(B), never the stale A.
// ---------------------------------------------------------------------------

func TestModifiedThenDeletedStreamIsConsistent(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)
	b := makeIngress("higress-system", "canary-test", "uid-b", map[string]string{"app": "canary-v2"})

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)

	// Publish B and let the SDK change callback fire, then delete the config.
	// Whether the callback-driven reconcile observed B before the deletion
	// depends on production interleaving, and the stream must stay
	// self-consistent in every one of them: a Deleted(B) may only follow an
	// observed Modified(B), and Deleted(A) is only legal when B was never
	// surfaced.
	client.setContent(t, group, dataId, encodeIngress(t, b))
	client.fireChange(group, dataId, encodeIngress(t, b))
	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)

	trailing := w.drainUntilSettled(t, testSettleTimeout)
	sawModifiedB := false
	for _, ev := range trailing {
		switch ev.Type {
		case watch.Modified:
			assertEventObject(t, ev, watch.Modified, b)
			sawModifiedB = true
		case watch.Deleted:
			if sawModifiedB {
				// Baseline red light: the deletion re-decodes the stale
				// cached content and reports Deleted(A) after Modified(B).
				assertEventObject(t, ev, watch.Deleted, b)
			} else {
				assertEventObject(t, ev, watch.Deleted, a)
			}
		default:
			t.Fatalf("unexpected event in stream: %s", describeEvents(trailing))
		}
	}
	// The stream must terminate cleanly after the deletion is reconciled.
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)
	if client.hasListener(group, dataId) {
		t.Fatalf("listener survived the deletion of the resource")
	}
}

// ---------------------------------------------------------------------------
// Contract 3 + §3.3: watch bootstrap must be ordered atomically against
// reconcile. A watcher created after a deletion completed must never observe
// only Added(A); its stream is either empty or Added(A) -> Deleted(A).
// ---------------------------------------------------------------------------

func TestWatchNeverResurrectsDeletedObject(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)

	w1 := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w1.collect(t, 1)[0], watch.Added, a)

	// One-shot hook inside SearchConfig: the baseline Watch performs an
	// independent List whose page was already snapshotted when the hook fires,
	// then registers the watcher afterwards. The hook deletes A and completes
	// a full reconcile before the stale page is handed back, so any baseline
	// watcher registered from that stale page must not resurrect A.
	//
	// The hook only ever fires on the baseline path (the fixed Watch builds
	// its bootstrap snapshot from reconcile state without calling SearchConfig
	// once a snapshot exists), and it requires that no reconcile lock is held
	// by the caller — true for the baseline Watch/List path.
	client.onSearch = func() {
		client.removeConfig(t, group, dataId)
		n.refreshConfigList()
	}

	w2 := mustWatch(t, n, nil, nil) // baseline: blocks inside the armed hook
	// On the baseline path the hook was consumed inside w2's Watch; the fixed
	// path never calls SearchConfig once a snapshot exists, so the hook is
	// still armed here. Disarm it before driving any reconcile of our own —
	// the hook is only meant to fire inside the baseline Watch bootstrap.
	client.mu.Lock()
	client.onSearch = nil
	client.mu.Unlock()
	waitForWatcherCount(t, n, 2)

	// Finish the deletion deterministically on the fixed path too; on the
	// baseline path the hook already deleted the config, so these are no-ops.
	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)

	assertEventObject(t, w1.collect(t, 1)[0], watch.Deleted, a)

	trailing := w2.drainUntilSettled(t, testSettleTimeout)
	if len(trailing) == 0 {
		return
	}
	if len(trailing) != 2 {
		t.Fatalf("fresh watcher after completed deletion observed an illegal stream: %s", describeEvents(trailing))
	}
	assertEventObject(t, trailing[0], watch.Added, a)
	assertEventObject(t, trailing[1], watch.Deleted, a)
}

// ---------------------------------------------------------------------------
// Contract 4 + §3.4.6: a config that never decoded must not fabricate objects
// or events, must still get a listener so a later fix wakes the reconcile,
// and its deletion must clean up state without emitting anything.
// ---------------------------------------------------------------------------

func TestNeverValidConfigThenDeleteEmitsNothing(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, "x")
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)

	// Whether a listener survived is implementation-dependent at this point;
	// if one did, the late callback it delivers must not resurrect anything.
	client.fireChange(group, dataId, "late-callback")
	assertNoMoreEvents(t, w)
}

func TestInvalidConfigGetsListenerAndLaterBecomesValid(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, "x")
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)
	if !client.hasListener(group, dataId) {
		t.Fatalf("initially invalid config was not registered for change listening")
	}

	// A listener-callback wake plus a reconcile must surface the fixed config
	// as Added with full identity.
	client.setContent(t, group, dataId, encodeIngress(t, a))
	client.fireChange(group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, a)
	assertNoMoreEvents(t, w)
}

// ---------------------------------------------------------------------------
// §3.4.6: a failed ListenConfig must be retried on later reconciles and must
// not be recorded as if it had succeeded.
// ---------------------------------------------------------------------------

func TestListenerRetryAfterInitialFailure(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)

	client.mu.Lock()
	client.listenErrs[configKey(group, dataId)] = errors.New("listen refused")
	client.mu.Unlock()

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)
	if client.hasListener(group, dataId) {
		t.Fatalf("ListenConfig failure was recorded as success")
	}

	client.mu.Lock()
	delete(client.listenErrs, configKey(group, dataId))
	client.mu.Unlock()

	// Baseline red light: the key is no longer "new" on later reconciles, so
	// the listener is never retried.
	refreshBlocking(t, n)
	if !client.hasListener(group, dataId) {
		t.Fatalf("failed listener registration was not retried by the next reconcile")
	}

	// The retried listener must keep working: content changes reach watchers.
	b := makeIngress("higress-system", "canary-test", "uid-b", nil)
	client.setContent(t, group, dataId, encodeIngress(t, b))
	client.fireChange(group, dataId, encodeIngress(t, b))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Modified, b)
}

// ---------------------------------------------------------------------------
// Contract 6: a failed enumeration (including a second-page failure) keeps the
// previous complete state and never reports spurious deletions.
// ---------------------------------------------------------------------------

func TestPartialEnumerationFailureKeepsAllObjects(t *testing.T) {
	n, client := newTestIngressREST(t)

	prevPageSize := options.NacosConfigSearchPageSize
	options.NacosConfigSearchPageSize = 1
	t.Cleanup(func() { options.NacosConfigSearchPageSize = prevPageSize })

	a := makeIngress("group-a", "canary-a", "uid-a", nil)
	b := makeIngress("group-b", "canary-b", "uid-b", nil)

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, "group-a", ingressDataId("canary-a"), encodeIngress(t, a))
	client.setContent(t, "group-b", ingressDataId("canary-b"), encodeIngress(t, b))
	refreshBlocking(t, n)
	added := w.collect(t, 2)
	assertEventObject(t, added[0], watch.Added, a)
	assertEventObject(t, added[1], watch.Added, b)

	client.mu.Lock()
	client.searchErrPage = 2
	client.searchErr = errors.New("page 2 unavailable")
	client.mu.Unlock()
	client.removeConfig(t, "group-b", ingressDataId("canary-b"))

	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)
	if !client.hasListener("group-a", ingressDataId("canary-a")) {
		t.Fatalf("failed enumeration dropped the listeners of surviving resources")
	}

	client.mu.Lock()
	client.searchErrPage = 0
	client.mu.Unlock()
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, b)
	assertNoMoreEvents(t, w)
	if !client.hasListener("group-a", ingressDataId("canary-a")) {
		t.Fatalf("recovered reconcile disturbed surviving resources")
	}
}

// ---------------------------------------------------------------------------
// §3.4.5: the names index must be rewritten (sorted keys, EMPTY placeholder)
// so removing the last resource does not leave a stale index behind.
// ---------------------------------------------------------------------------

func TestNamesIndexClearedWhenLastResourceRemoved(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)
	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	w.collect(t, 1)

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)
	w.collect(t, 1)

	client.mu.Lock()
	names := client.configs[configKey(namesGroup, n.namesDataId)]
	client.mu.Unlock()
	if names != emptyNamesPlaceholder {
		t.Fatalf("names index not reset to %q after last resource removed, got %q", emptyNamesPlaceholder, names)
	}
}

// ---------------------------------------------------------------------------
// Contract 5: deleting and recreating under the same name must produce a new
// Added with a fresh identity and a fresh listener registration.
// ---------------------------------------------------------------------------

func TestRecreateAfterDeleteUsesNewIdentity(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)
	a2 := makeIngress("higress-system", "canary-test", "uid-a2", map[string]string{"app": "v2"})

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, a)
	if client.hasListener(group, dataId) {
		t.Fatalf("old listener survived deletion")
	}

	client.setContent(t, group, dataId, encodeIngress(t, a2))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a2)
	if !client.hasListener(group, dataId) {
		t.Fatalf("recreated resource has no listener registration")
	}

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, a2)
	assertNoMoreEvents(t, w)
}

// ---------------------------------------------------------------------------
// Contract 7: repeated snapshots, repeated callbacks and repeated deletions
// must not duplicate events.
// ---------------------------------------------------------------------------

func TestNoDuplicateEventsAcrossRefreshesAndCallbacks(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)
	b := makeIngress("higress-system", "canary-test", "uid-b", nil)

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)

	for i := 0; i < 3; i++ {
		refreshBlocking(t, n)
	}
	client.fireChange(group, dataId, encodeIngress(t, a))
	assertNoMoreEvents(t, w)

	client.setContent(t, group, dataId, encodeIngress(t, b))
	for i := 0; i < 3; i++ {
		client.fireChange(group, dataId, encodeIngress(t, b))
	}
	refreshBlocking(t, n)
	modified := w.collect(t, 1)
	assertEventObject(t, modified[0], watch.Modified, b)
	assertNoMoreEvents(t, w)

	client.removeConfig(t, group, dataId)
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Deleted, b)
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)
}

// ---------------------------------------------------------------------------
// Contract 7: watchers for different namespaces, label selectors and
// group/dataId keys are isolated.
// ---------------------------------------------------------------------------

func TestWatcherNamespaceLabelAndGroupIsolation(t *testing.T) {
	n, client := newTestIngressREST(t)
	a := makeIngress("ns1", "canary-test", "uid-a", map[string]string{"app": "canary"})

	wAll := mustWatch(t, n, nil, nil)
	ns2Ctx := genericapirequest.WithNamespace(context.Background(), "ns2")
	wNS2 := mustWatch(t, n, ns2Ctx, nil)
	wLabel := mustWatch(t, n, nil, &metainternalversion.ListOptions{
		LabelSelector: labels.Set{"app": "other"}.AsSelector(),
	})

	client.setContent(t, "ns1", ingressDataId("canary-test"), encodeIngress(t, a))
	refreshBlocking(t, n)
	assertEventObject(t, wAll.collect(t, 1)[0], watch.Added, a)
	assertNoMoreEvents(t, wNS2)
	assertNoMoreEvents(t, wLabel)

	client.removeConfig(t, "ns1", ingressDataId("canary-test"))
	refreshBlocking(t, n)
	assertEventObject(t, wAll.collect(t, 1)[0], watch.Deleted, a)
	assertNoMoreEvents(t, wNS2)
	assertNoMoreEvents(t, wLabel)

	// Same dataId under a different group is an independent resource.
	c := makeIngress("ns2", "canary-test", "uid-c", nil)
	client.setContent(t, "ns2", ingressDataId("canary-test"), encodeIngress(t, c))
	refreshBlocking(t, n)
	assertEventObject(t, wAll.collect(t, 1)[0], watch.Added, c)
	assertEventObject(t, wNS2.collect(t, 1)[0], watch.Added, c)
	assertNoMoreEvents(t, wLabel)

	client.removeConfig(t, "ns2", ingressDataId("canary-test"))
	refreshBlocking(t, n)
	assertEventObject(t, wAll.collect(t, 1)[0], watch.Deleted, c)
	assertEventObject(t, wNS2.collect(t, 1)[0], watch.Deleted, c)
	assertNoMoreEvents(t, wLabel)
}

// ---------------------------------------------------------------------------
// §3.2: an SDK firing the change callback synchronously inside ListenConfig
// must not deadlock the reconcile, and the callback itself must not publish
// duplicate events.
// ---------------------------------------------------------------------------

func TestSyncListenerCallbackDoesNotDuplicateEvents(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)
	encoded := encodeIngress(t, a)

	client.mu.Lock()
	client.onListenSync = func(param vo.ConfigParam) {
		param.OnChange("", param.Group, param.DataId, encoded)
	}
	client.mu.Unlock()

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encoded)
	refreshBlocking(t, n)
	assertEventObject(t, w.collect(t, 1)[0], watch.Added, a)
	assertNoMoreEvents(t, w)
}

// ---------------------------------------------------------------------------
// §3.2: Destroy is idempotent, cancels all SDK listeners, and late callbacks
// after Destroy are ignored.
// ---------------------------------------------------------------------------

func TestDestroyIsIdempotentAndIgnoresLateCallbacks(t *testing.T) {
	n, client := newTestIngressREST(t)
	group, dataId := "higress-system", ingressDataId("canary-test")
	a := makeIngress("higress-system", "canary-test", "uid-a", nil)

	w := mustWatch(t, n, nil, nil)
	client.setContent(t, group, dataId, encodeIngress(t, a))
	refreshBlocking(t, n)
	w.collect(t, 1)

	n.Destroy()
	n.Destroy()

	if client.listenerCount() != 0 {
		t.Fatalf("Destroy left %d SDK listeners registered", client.listenerCount())
	}
	if client.fireChange(group, dataId, encodeIngress(t, a)) {
		t.Fatalf("resource listener survived Destroy; a late callback would still publish")
	}
	// Destroy terminates every watcher: its forwarder closes the result
	// channel without delivering any further event.
	select {
	case ev, ok := <-w.ch:
		if ok {
			t.Fatalf("event delivered after Destroy: %s", describeEvents([]watch.Event{ev}))
		}
	case <-time.After(testWaitTimeout):
		t.Fatalf("watch channel was not closed after Destroy")
	}
}

// ---------------------------------------------------------------------------
// Concurrency: callbacks, reconciles, watches and Destroy racing must not
// deadlock, panic or double-close channels. Run with -race.
// ---------------------------------------------------------------------------

func TestConcurrentCallbacksRefreshAndDestroy(t *testing.T) {
	n, client := newTestIngressREST(t)
	groups := []string{"group-a", "group-b", "group-c"}
	names := []string{"canary-x", "canary-y"}
	for _, g := range groups {
		for _, name := range names {
			obj := makeIngress(g, name, "uid-"+g+"-"+name, nil)
			client.setContent(t, g, ingressDataId(name), encodeIngress(t, obj))
		}
	}

	refreshBlocking(t, n)
	w := mustWatch(t, n, nil, nil)

	var wg sync.WaitGroup
	stop := make(chan struct{})

	for _, g := range groups {
		for _, name := range names {
			wg.Add(1)
			go func(g, name string) {
				defer wg.Done()
				obj := makeIngress(g, name, "uid-"+g+"-"+name, nil)
				encoded := encodeIngress(t, obj)
				for i := 0; i < 20; i++ {
					select {
					case <-stop:
						return
					default:
					}
					client.setContent(t, g, ingressDataId(name), encoded)
					client.fireChange(g, ingressDataId(name), encoded)
					n.refreshConfigList()
				}
			}(g, name)
		}
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 5; i++ {
			select {
			case <-stop:
				return
			default:
			}
			watcher, err := n.Watch(context.Background(), nil)
			if err != nil {
				continue
			}
			watcher.Stop()
		}
	}()

	// Let the racers overlap with Destroy, then drain everything.
	destroyDone := make(chan struct{})
	go func() {
		n.Destroy()
		close(destroyDone)
	}()
	select {
	case <-destroyDone:
	case <-time.After(testWaitTimeout):
		t.Fatalf("Destroy blocked under concurrent load")
	}
	close(stop)
	wg.Wait()

	go func() {
		for range w.ch {
		}
	}()
}

// ---------------------------------------------------------------------------
// §3.3: overflow of the bounded incremental queue must surface a Kubernetes
// 410 watch.Error demanding relist, must never silently drop events, and must
// never block the reconcile.
// ---------------------------------------------------------------------------

func TestOverflowQueueSendsExpiredAndKeepsReconcileLive(t *testing.T) {
	n, client := newTestIngressREST(t)

	// Registered while empty, and its ResultChan is deliberately never read
	// until after the reconcile completed.
	w := mustWatch(t, n, nil, nil)

	const total = 1024 + 76
	for i := 0; i < total; i++ {
		obj := makeIngress("bulk", fmt.Sprintf("ing-%04d", i), fmt.Sprintf("uid-%04d", i), nil)
		client.setContent(t, "bulk", ingressDataId(fmt.Sprintf("ing-%04d", i)), encodeIngress(t, obj))
	}

	refreshBlocking(t, n) // must complete even though the consumer is idle

	// The forwarder may already have delivered a handful of queued events
	// before the overflow signal won the race; the hard guarantees are that a
	// 410 relist signal arrives, nothing follows it, and the channel closes.
	var status *metav1.Status
	deadline := time.After(testWaitTimeout)
	for status == nil {
		select {
		case ev, ok := <-w.ch:
			if !ok {
				t.Fatalf("watch channel closed before the 410 overflow signal")
			}
			if ev.Type == watch.Error {
				st, ok := ev.Object.(*metav1.Status)
				if !ok {
					t.Fatalf("watch.Error object is %T, want *metav1.Status", ev.Object)
				}
				status = st
			}
		case <-deadline:
			t.Fatalf("timed out waiting for the 410 overflow signal; got %s", describeEvents(nil))
		}
	}
	if status.Code != http.StatusGone || status.Reason != metav1.StatusReasonExpired {
		t.Fatalf("watch.Error is not a 410 relist signal: code=%d reason=%s", status.Code, status.Reason)
	}
	select {
	case ev, ok := <-w.ch:
		if ok {
			t.Fatalf("expected channel close after 410, got %s", describeEvents([]watch.Event{ev}))
		}
	case <-time.After(testWaitTimeout):
		t.Fatalf("watch channel was not closed after the 410 error event")
	}
}

func TestDestroyCompletesWithBlockedConsumer(t *testing.T) {
	n, client := newTestIngressREST(t)
	w := mustWatch(t, n, nil, nil) // never read

	const total = 1024 + 76
	for i := 0; i < total; i++ {
		obj := makeIngress("bulk", fmt.Sprintf("ing-%04d", i), fmt.Sprintf("uid-%04d", i), nil)
		client.setContent(t, "bulk", ingressDataId(fmt.Sprintf("ing-%04d", i)), encodeIngress(t, obj))
	}
	refreshBlocking(t, n)

	destroyDone := make(chan struct{})
	go func() {
		n.Destroy()
		close(destroyDone)
	}()
	select {
	case <-destroyDone:
	case <-time.After(testWaitTimeout):
		t.Fatalf("Destroy blocked while a watcher output was stuck and its queue was full")
	}

	for {
		select {
		case _, ok := <-w.ch:
			if !ok {
				return
			}
		case <-time.After(testWaitTimeout):
			t.Fatalf("watch channel was not closed after Destroy")
		}
	}
}

// ---------------------------------------------------------------------------
// §3.3: the initial snapshot is not funneled through the bounded incremental
// queue, so more than 1024 initial objects cannot overflow themselves.
// ---------------------------------------------------------------------------

func TestLargeInitialSnapshotDeliveredFully(t *testing.T) {
	n, client := newTestIngressREST(t)

	const total = 1024 + 476
	for i := 0; i < total; i++ {
		obj := makeIngress("bulk", fmt.Sprintf("ing-%04d", i), fmt.Sprintf("uid-%04d", i), nil)
		client.setContent(t, "bulk", ingressDataId(fmt.Sprintf("ing-%04d", i)), encodeIngress(t, obj))
	}
	refreshBlocking(t, n)

	w := mustWatch(t, n, nil, nil)
	added := w.collect(t, total)
	for _, ev := range added {
		if ev.Type != watch.Added {
			t.Fatalf("initial snapshot delivered %s event: %s", ev.Type, describeEvents(added[:1]))
		}
	}
	// One more reconcile must not invent further events.
	refreshBlocking(t, n)
	assertNoMoreEvents(t, w)
}

// ---------------------------------------------------------------------------
// §3.3: when no reconcile snapshot exists yet and enumeration fails, Watch
// must fail loudly instead of returning a seemingly-complete empty stream.
// ---------------------------------------------------------------------------

func TestWatchFailsWhenInitialSnapshotUnavailable(t *testing.T) {
	n, client := newTestIngressREST(t)
	client.mu.Lock()
	client.searchErrPage = 1
	client.searchErr = errors.New("nacos unavailable")
	client.mu.Unlock()

	w, err := n.Watch(context.Background(), nil)
	if err == nil {
		w.Stop()
		t.Fatalf("Watch succeeded despite a failed initial enumeration")
	}
	if w != nil {
		t.Fatalf("Watch returned a watcher together with an error")
	}
}
