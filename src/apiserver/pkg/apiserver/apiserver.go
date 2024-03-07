/*
Copyright 2016 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package apiserver

import (
	"fmt"

	admregv1 "k8s.io/api/admissionregistration/v1"
	authzv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	networkingv1 "k8s.io/api/networking/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/apimachinery/pkg/version"
	"k8s.io/apiserver/pkg/registry/rest"
	genericapiserver "k8s.io/apiserver/pkg/server"
	genericserverstorage "k8s.io/apiserver/pkg/server/storage"
	genericstorage "k8s.io/apiserver/pkg/storage"
	"k8s.io/apiserver/pkg/storage/storagebackend"
	gwapiv1alpha2 "sigs.k8s.io/gateway-api/apis/v1alpha2"
	gwapiv1beta1 "sigs.k8s.io/gateway-api/apis/v1beta1"

	gwapiv1 "github.com/alibaba/higress/api-server/pkg/apis/gatewayapi/v1"
	"github.com/alibaba/higress/api-server/pkg/codec"
	"github.com/alibaba/higress/api-server/pkg/converter"
	"github.com/alibaba/higress/api-server/pkg/options"
	"github.com/alibaba/higress/api-server/pkg/registry"
	"github.com/alibaba/higress/api-server/pkg/storage"
	hiextensionsv1alpha1 "github.com/alibaba/higress/client/pkg/apis/extensions/v1alpha1"
	hinetworkingv1 "github.com/alibaba/higress/client/pkg/apis/networking/v1"
	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
)

type storageCreator func(
	groupResource schema.GroupResource,
	codec runtime.Codec,
	isNamespaced bool,
	singularName string,
	newFunc func() runtime.Object,
	newListFunc func() runtime.Object,
	attrFunc genericstorage.AttrFunc,
	sensitive bool,
) (rest.Storage, error)

const (
	contentType = runtime.ContentTypeYAML
	extension   = ".yaml"
)

var (
	// Scheme defines methods for serializing and deserializing API objects.
	Scheme = runtime.NewScheme()
	// Codecs provides methods for retrieving codecs and serializers for specific
	// versions and content types.
	Codecs                     = serializer.NewCodecFactory(Scheme)
	LegacyNegotiatedSerializer = codec.CreateLegacyNegotiatedSerializer(Scheme)
)

func init() {
	_ = corev1.AddToScheme(Scheme)
	_ = admregv1.AddToScheme(Scheme)
	_ = Scheme.AddFieldLabelConversionFunc(corev1.SchemeGroupVersion.WithKind("Secret"),
		func(label, value string) (internalLabel, internalValue string, err error) {
			switch label {
			case "type":
				return label, value, nil
			default:
				return runtime.DefaultMetaV1FieldSelectorConversion(label, value)
			}
		})
	_ = apiextensionsv1.AddToScheme(Scheme)
	_ = authzv1.AddToScheme(Scheme)
	_ = networkingv1.AddToScheme(Scheme)
	_ = discoveryv1.AddToScheme(Scheme)
	_ = hiextensionsv1alpha1.AddToScheme(Scheme)
	_ = hinetworkingv1.AddToScheme(Scheme)
	_ = gwapiv1beta1.AddToScheme(Scheme)
	_ = gwapiv1.AddToScheme(Scheme)
	_ = gwapiv1alpha2.AddToScheme(Scheme)

	// TODO: keep the generic API server from wanting this
	unversioned := schema.GroupVersion{Group: "", Version: "v1"}
	Scheme.AddUnversionedTypes(unversioned,
		&metav1.Status{},
		&metav1.APIVersions{},
		&metav1.APIGroupList{},
		&metav1.APIGroup{},
		&metav1.APIResourceList{},
	)
}

// ExtraConfig holds custom apiserver config
type ExtraConfig struct {
	AuthOptions    *options.AuthOptions
	StorageOptions *options.StorageOptions
}

// Config defines the config for the apiserver
type Config struct {
	GenericConfig *genericapiserver.RecommendedConfig
	ExtraConfig   ExtraConfig
}

// HigressServer contains state for a Kubernetes cluster master/api server.
type HigressServer struct {
	GenericAPIServer *genericapiserver.GenericAPIServer
}

type completedConfig struct {
	GenericConfig genericapiserver.CompletedConfig
	ExtraConfig   *ExtraConfig
}

// CompletedConfig embeds a private pointer that cannot be instantiated outside of this package.
type CompletedConfig struct {
	*completedConfig
}

// Complete fills in any fields not set that are required to have valid data. It's mutating the receiver.
func (cfg *Config) Complete() CompletedConfig {
	c := completedConfig{
		cfg.GenericConfig.Complete(),
		&cfg.ExtraConfig,
	}

	// Set version to 1.19.0 so client can use networking.k8s.io/v1 instead of networking.k8s.io/v1beta1
	c.GenericConfig.Version = &version.Info{
		Major:      "1",
		Minor:      "19",
		GitVersion: "v1.19.0",
	}

	return CompletedConfig{&c}
}

// New returns a new instance of HigressServer from the given config.
func (c completedConfig) New() (*HigressServer, error) {
	genericServer, err := c.GenericConfig.New("higress-apiserver", genericapiserver.NewEmptyDelegate())
	if err != nil {
		return nil, err
	}

	s := &HigressServer{
		GenericAPIServer: genericServer,
	}

	storageOptions := c.ExtraConfig.StorageOptions
	storageMode := storageOptions.Mode
	var nacosConfigClient config_client.IConfigClient
	if storageMode == options.Storage_Nacos {
		nacosOptions := c.ExtraConfig.StorageOptions.NacosOptions
		nacosConfigClient, err = nacosOptions.CreateConfigClient()
		if err != nil {
			return nil, err
		}
	}

	storageCreateFunc := func(
		groupResource schema.GroupResource,
		runtimeCodec runtime.Codec,
		isNamespaced bool,
		singularName string,
		newFunc func() runtime.Object,
		newListFunc func() runtime.Object,
		attrFunc genericstorage.AttrFunc,
		sensitive bool,
	) (rest.Storage, error) {
		if groupResource == apiextensionsv1.Resource("customresourcedefinitions") {
			return storage.CreateCustomResourceDefinitionStorage(runtimeCodec)
		}
		switch storageMode {
		case options.Storage_File:
			runtimeCodec = codec.NewFlatAwareCodec(groupResource, runtimeCodec)
			return registry.NewFileREST(groupResource, runtimeCodec, storageOptions.FileOptions.RootDir, extension, isNamespaced, singularName, newFunc, newListFunc, attrFunc)
		case options.Storage_Nacos:
			var encryptionKey []byte = nil
			if sensitive {
				encryptionKey = storageOptions.NacosOptions.EncryptionKey
			}
			return registry.NewNacosREST(groupResource, runtimeCodec, nacosConfigClient, isNamespaced, singularName, newFunc, newListFunc, attrFunc, encryptionKey), nil
		default:
			panic(fmt.Errorf("invalid storage mode: %s", storageMode))
		}
	}

	converter.RegisterConverters(Scheme)

	{
		coreApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(corev1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		corev1Storages := map[string]rest.Storage{}
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "configmap", "configmaps",
			func() runtime.Object { return &corev1.ConfigMap{} },
			func() runtime.Object { return &corev1.ConfigMapList{} },
			nil, false)
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "secret", "secrets",
			func() runtime.Object { return &corev1.Secret{} },
			func() runtime.Object { return &corev1.SecretList{} },
			func(obj runtime.Object) (labels.Set, fields.Set, error) {
				labels, fields, err := genericstorage.DefaultNamespaceScopedAttr(obj)
				if err != nil {
					return labels, fields, err
				}
				secret, ok := obj.(*corev1.Secret)
				if !ok {
					return labels, fields, err
				}
				fields["type"] = string(secret.Type)
				return labels, fields, err
			}, true)
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "service", "services",
			func() runtime.Object { return &corev1.Service{} },
			func() runtime.Object { return &corev1.ServiceList{} },
			nil, false)
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "endpoints", "endpoints",
			func() runtime.Object { return &corev1.Endpoints{} },
			func() runtime.Object { return &corev1.EndpointsList{} },
			nil, false)
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "pod", "pods",
			func() runtime.Object { return &corev1.Pod{} },
			func() runtime.Object { return &corev1.PodList{} },
			nil, false)
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "node", "nodes",
			func() runtime.Object { return &corev1.Node{} },
			func() runtime.Object { return &corev1.NodeList{} },
			nil, false)
		appendStorage(corev1Storages, storageCreateFunc, corev1.SchemeGroupVersion, true, "namespace", "namespaces",
			func() runtime.Object { return &corev1.Namespace{} },
			func() runtime.Object { return &corev1.NamespaceList{} },
			nil, false)
		coreApiGroupInfo.VersionedResourcesStorageMap[corev1.SchemeGroupVersion.Version] = corev1Storages
		if err := s.GenericAPIServer.InstallLegacyAPIGroup("/api", &coreApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		apiExtensionsApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(apiextensionsv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		apiExtensionsStorages := map[string]rest.Storage{}
		appendStorage(apiExtensionsStorages, storageCreateFunc, apiextensionsv1.SchemeGroupVersion, false, "customresourcedefinition", "customresourcedefinitions",
			func() runtime.Object { return &apiextensionsv1.CustomResourceDefinition{} },
			func() runtime.Object { return &apiextensionsv1.CustomResourceDefinitionList{} },
			nil, false)
		apiExtensionsApiGroupInfo.VersionedResourcesStorageMap[apiextensionsv1.SchemeGroupVersion.Version] = apiExtensionsStorages
		if err := s.GenericAPIServer.InstallAPIGroup(&apiExtensionsApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		admRegApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(admregv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		admRegv1Storages := map[string]rest.Storage{}
		appendStorage(admRegv1Storages, storageCreateFunc, admregv1.SchemeGroupVersion, true, "mutatingwebhookconfiguration", "mutatingwebhookconfigurations",
			func() runtime.Object { return &admregv1.MutatingWebhookConfiguration{} },
			func() runtime.Object { return &admregv1.MutatingWebhookConfigurationList{} },
			nil, false)
		appendStorage(admRegv1Storages, storageCreateFunc, admregv1.SchemeGroupVersion, true, "validatingwebhookconfiguration", "validatingwebhookconfigurations",
			func() runtime.Object { return &admregv1.ValidatingWebhookConfiguration{} },
			func() runtime.Object { return &admregv1.ValidatingWebhookConfigurationList{} },
			nil, false)
		admRegApiGroupInfo.VersionedResourcesStorageMap[admregv1.SchemeGroupVersion.Version] = admRegv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&admRegApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		authzApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(authzv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		authzv1Storages := map[string]rest.Storage{}
		authzv1Storages["subjectaccessreviews"] = &storage.SubjectAccessReviewStorage{}
		authzApiGroupInfo.VersionedResourcesStorageMap[authzv1.SchemeGroupVersion.Version] = authzv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&authzApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		discoveryApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(discoveryv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		discoveryv1Storages := map[string]rest.Storage{}
		appendStorage(discoveryv1Storages, storageCreateFunc, discoveryv1.SchemeGroupVersion, true, "endpointslice", "endpointslices",
			func() runtime.Object { return &discoveryv1.EndpointSlice{} },
			func() runtime.Object { return &discoveryv1.EndpointSliceList{} },
			nil, false)
		discoveryApiGroupInfo.VersionedResourcesStorageMap[discoveryv1.SchemeGroupVersion.Version] = discoveryv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&discoveryApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		networkingApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(networkingv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		networkingv1Storages := map[string]rest.Storage{}
		appendStorage(networkingv1Storages, storageCreateFunc, networkingv1.SchemeGroupVersion, true, "ingress", "ingresses",
			func() runtime.Object { return &networkingv1.Ingress{} },
			func() runtime.Object { return &networkingv1.IngressList{} },
			nil, false)
		appendStorage(networkingv1Storages, storageCreateFunc, networkingv1.SchemeGroupVersion, true, "ingressclass", "ingressclasses",
			func() runtime.Object { return &networkingv1.IngressClass{} },
			func() runtime.Object { return &networkingv1.IngressClassList{} },
			nil, false)
		networkingApiGroupInfo.VersionedResourcesStorageMap[networkingv1.SchemeGroupVersion.Version] = networkingv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&networkingApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		hiextensionApiGroupInfo := newLegacyAPIGroupInfo(hiextensionsv1alpha1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec)
		hiextensionv1alphaStorages := map[string]rest.Storage{}
		appendStorage(hiextensionv1alphaStorages, storageCreateFunc, hiextensionsv1alpha1.SchemeGroupVersion, true, "wasmplugin", "wasmplugins",
			func() runtime.Object { return &hiextensionsv1alpha1.WasmPlugin{} },
			func() runtime.Object { return &hiextensionsv1alpha1.WasmPluginList{} },
			nil, false)
		hiextensionApiGroupInfo.VersionedResourcesStorageMap[hiextensionsv1alpha1.SchemeGroupVersion.Version] = hiextensionv1alphaStorages
		if err := s.GenericAPIServer.InstallAPIGroup(&hiextensionApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		hinetworkingApiGroupInfo := newLegacyAPIGroupInfo(hinetworkingv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec)
		hinetworkingv1Storages := map[string]rest.Storage{}
		appendStorage(hinetworkingv1Storages, storageCreateFunc, hinetworkingv1.SchemeGroupVersion, true, "mcpbridge", "mcpbridges",
			func() runtime.Object { return &hinetworkingv1.McpBridge{} },
			func() runtime.Object { return &hinetworkingv1.McpBridgeList{} },
			nil, false)
		appendStorage(hinetworkingv1Storages, storageCreateFunc, hinetworkingv1.SchemeGroupVersion, true, "http2rpc", "http2rpcs",
			func() runtime.Object { return &hinetworkingv1.Http2Rpc{} },
			func() runtime.Object { return &hinetworkingv1.Http2RpcList{} },
			nil, false)
		hinetworkingApiGroupInfo.VersionedResourcesStorageMap[hinetworkingv1.SchemeGroupVersion.Version] = hinetworkingv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&hinetworkingApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		gwapiApiGroupInfo := newLegacyAPIGroupInfo(gwapiv1beta1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec)
		gwapiv1beta1Storages := map[string]rest.Storage{}
		appendStorage(gwapiv1beta1Storages, storageCreateFunc, gwapiv1beta1.SchemeGroupVersion, false, "gatewayclass", "gatewayclasses",
			func() runtime.Object { return &gwapiv1beta1.GatewayClass{} },
			func() runtime.Object { return &gwapiv1beta1.GatewayClassList{} },
			nil, false)
		appendStorage(gwapiv1beta1Storages, storageCreateFunc, gwapiv1beta1.SchemeGroupVersion, true, "gateway", "gateways",
			func() runtime.Object { return &gwapiv1beta1.Gateway{} },
			func() runtime.Object { return &gwapiv1beta1.GatewayList{} },
			nil, false)
		appendStorage(gwapiv1beta1Storages, storageCreateFunc, gwapiv1beta1.SchemeGroupVersion, true, "httproute", "httproutes",
			func() runtime.Object { return &gwapiv1beta1.HTTPRoute{} },
			func() runtime.Object { return &gwapiv1beta1.HTTPRouteList{} },
			nil, false)
		appendStorage(gwapiv1beta1Storages, storageCreateFunc, gwapiv1beta1.SchemeGroupVersion, true, "referencegrant", "referencegrants",
			func() runtime.Object { return &gwapiv1beta1.ReferenceGrant{} },
			func() runtime.Object { return &gwapiv1beta1.ReferenceGrantList{} },
			nil, false)
		gwapiApiGroupInfo.VersionedResourcesStorageMap[gwapiv1beta1.SchemeGroupVersion.Version] = gwapiv1beta1Storages
		gwapiApiGroupInfo.VersionedResourcesStorageMap[gwapiv1alpha2.SchemeGroupVersion.Version] = gwapiv1beta1Storages
		gwapiApiGroupInfo.VersionedResourcesStorageMap[gwapiv1.SchemeGroupVersion.Version] = gwapiv1beta1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&gwapiApiGroupInfo); err != nil {
			return nil, err
		}
	}

	return s, nil
}

func newLegacyAPIGroupInfo(group string, scheme *runtime.Scheme, parameterCodec runtime.ParameterCodec) genericapiserver.APIGroupInfo {
	return genericapiserver.APIGroupInfo{
		PrioritizedVersions:          scheme.PrioritizedVersionsForGroup(group),
		VersionedResourcesStorageMap: map[string]map[string]rest.Storage{},
		// TODO unhardcode this.  It was hardcoded before, but we need to re-evaluate
		OptionsExternalVersion: &schema.GroupVersion{Version: "v1"},
		Scheme:                 scheme,
		ParameterCodec:         parameterCodec,
		NegotiatedSerializer:   LegacyNegotiatedSerializer,
	}
}

func appendStorage(storages map[string]rest.Storage,
	storageCreatorFunc storageCreator,
	groupVersion schema.GroupVersion,
	isNamespaced bool,
	singularName string,
	pluralName string,
	newFunc func() runtime.Object,
	newListFunc func() runtime.Object,
	attrFunc genericstorage.AttrFunc,
	sensitive bool,
) {
	groupResource := groupVersion.WithResource(pluralName).GroupResource()
	storageCodec, _, err := genericserverstorage.NewStorageCodec(genericserverstorage.StorageCodecConfig{
		StorageMediaType:  contentType,
		StorageSerializer: serializer.NewCodecFactory(Scheme),
		StorageVersion:    Scheme.PrioritizedVersionsForGroup(groupResource.Group)[0],
		MemoryVersion:     Scheme.PrioritizedVersionsForGroup(groupResource.Group)[0],
		Config:            storagebackend.Config{}, // useless fields
	})
	if err != nil {
		err = fmt.Errorf("unable to create storage codec for a resource due to %v, will die", err)
		panic(err)
	}
	storage, err := storageCreatorFunc(groupResource, storageCodec, isNamespaced, singularName, newFunc, newListFunc, attrFunc, sensitive)
	if err != nil {
		err = fmt.Errorf("unable to create REST storage for a resource due to %v, will die", err)
		panic(err)
	}
	storages[pluralName] = storage
}
