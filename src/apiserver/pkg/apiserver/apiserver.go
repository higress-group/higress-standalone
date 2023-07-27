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
	"github.com/alibaba/higress/api-server/pkg/options"
	"github.com/alibaba/higress/api-server/pkg/registry"
	"github.com/alibaba/higress/api-server/pkg/storage"
	hiextensionsv1alpha1 "github.com/alibaba/higress/client/pkg/apis/extensions/v1alpha1"
	hinetworkingv1 "github.com/alibaba/higress/client/pkg/apis/networking/v1"
	"github.com/nacos-group/nacos-sdk-go/v2/clients/config_client"
	admregv1 "k8s.io/api/admissionregistration/v1"
	authzv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
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
)

const (
	contentType = runtime.ContentTypeYAML
)

var (
	// Scheme defines methods for serializing and deserializing API objects.
	Scheme = runtime.NewScheme()
	// Codecs provides methods for retrieving codecs and serializers for specific
	// versions and content types.
	Codecs = serializer.NewCodecFactory(Scheme)
)

func init() {
	_ = corev1.AddToScheme(Scheme)
	metav1.AddToGroupVersion(Scheme, corev1.SchemeGroupVersion)
	_ = admregv1.AddToScheme(Scheme)
	metav1.AddToGroupVersion(Scheme, admregv1.SchemeGroupVersion)
	_ = authzv1.AddToScheme(Scheme)
	metav1.AddToGroupVersion(Scheme, authzv1.SchemeGroupVersion)
	_ = networkingv1.AddToScheme(Scheme)
	metav1.AddToGroupVersion(Scheme, networkingv1.SchemeGroupVersion)
	_ = hiextensionsv1alpha1.AddToScheme(Scheme)
	metav1.AddToGroupVersion(Scheme, hiextensionsv1alpha1.SchemeGroupVersion)
	_ = hinetworkingv1.AddToScheme(Scheme)
	metav1.AddToGroupVersion(Scheme, hinetworkingv1.SchemeGroupVersion)
	_ = Scheme.AddFieldLabelConversionFunc(corev1.SchemeGroupVersion.WithKind("Secret"),
		func(label, value string) (internalLabel, internalValue string, err error) {
			switch label {
			case "type":
				return label, value, nil
			default:
				return runtime.DefaultMetaV1FieldSelectorConversion(label, value)
			}
		})

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
	NacosOptions *options.NacosOptions
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

	nacosOptions := c.ExtraConfig.NacosOptions
	configClient, err := nacosOptions.CreateConfigClient()
	if err != nil {
		return nil, err
	}

	{
		corev1ApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(corev1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		corev1Storages := map[string]rest.Storage{}
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "configmap", "configmaps",
			func() runtime.Object { return &corev1.ConfigMap{} },
			func() runtime.Object { return &corev1.ConfigMapList{} },
			nil, nil)
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "secret", "secrets",
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
			}, nacosOptions.EncryptionKey)
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "service", "services",
			func() runtime.Object { return &corev1.Service{} },
			func() runtime.Object { return &corev1.ServiceList{} },
			nil, nil)
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "endpoints", "endpoints",
			func() runtime.Object { return &corev1.Endpoints{} },
			func() runtime.Object { return &corev1.EndpointsList{} },
			nil, nil)
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "pod", "pods",
			func() runtime.Object { return &corev1.Pod{} },
			func() runtime.Object { return &corev1.PodList{} },
			nil, nil)
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "node", "nodes",
			func() runtime.Object { return &corev1.Node{} },
			func() runtime.Object { return &corev1.NodeList{} },
			nil, nil)
		appendStorage(corev1Storages, configClient, corev1.SchemeGroupVersion, true, "namespace", "namespaces",
			func() runtime.Object { return &corev1.Namespace{} },
			func() runtime.Object { return &corev1.NamespaceList{} },
			nil, nil)
		corev1ApiGroupInfo.VersionedResourcesStorageMap[corev1.SchemeGroupVersion.Version] = corev1Storages
		if err := s.GenericAPIServer.InstallLegacyAPIGroup("/api", &corev1ApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		admRegv1ApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(admregv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		admRegv1Storages := map[string]rest.Storage{}
		appendStorage(admRegv1Storages, configClient, admregv1.SchemeGroupVersion, true, "mutatingwebhookconfiguration", "mutatingwebhookconfigurations",
			func() runtime.Object { return &admregv1.MutatingWebhookConfiguration{} },
			func() runtime.Object { return &admregv1.MutatingWebhookConfigurationList{} },
			nil, nil)
		appendStorage(admRegv1Storages, configClient, admregv1.SchemeGroupVersion, true, "validatingwebhookconfiguration", "validatingwebhookconfigurations",
			func() runtime.Object { return &admregv1.ValidatingWebhookConfiguration{} },
			func() runtime.Object { return &admregv1.ValidatingWebhookConfigurationList{} },
			nil, nil)
		admRegv1ApiGroupInfo.VersionedResourcesStorageMap[admregv1.SchemeGroupVersion.Version] = admRegv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&admRegv1ApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		authzv1ApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(authzv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		authzv1Storages := map[string]rest.Storage{}
		authzv1Storages["subjectaccessreviews"] = &storage.SubjectAccessReviewStorage{}
		authzv1ApiGroupInfo.VersionedResourcesStorageMap[authzv1.SchemeGroupVersion.Version] = authzv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&authzv1ApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		networkingv1ApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(networkingv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		networkingv1Storages := map[string]rest.Storage{}
		appendStorage(networkingv1Storages, configClient, networkingv1.SchemeGroupVersion, true, "ingress", "ingresses",
			func() runtime.Object { return &networkingv1.Ingress{} },
			func() runtime.Object { return &networkingv1.IngressList{} },
			nil, nil)
		appendStorage(networkingv1Storages, configClient, networkingv1.SchemeGroupVersion, true, "ingressclass", "ingressclasses",
			func() runtime.Object { return &networkingv1.IngressClass{} },
			func() runtime.Object { return &networkingv1.IngressClassList{} },
			nil, nil)
		networkingv1ApiGroupInfo.VersionedResourcesStorageMap[networkingv1.SchemeGroupVersion.Version] = networkingv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&networkingv1ApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		hiextensionv1alphaApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(hiextensionsv1alpha1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		hiextensionv1alphaStorages := map[string]rest.Storage{}
		appendStorage(hiextensionv1alphaStorages, configClient, hiextensionsv1alpha1.SchemeGroupVersion, true, "wasmplugin", "wasmplugins",
			func() runtime.Object { return &hiextensionsv1alpha1.WasmPlugin{} },
			func() runtime.Object { return &hiextensionsv1alpha1.WasmPluginList{} },
			nil, nil)
		hiextensionv1alphaApiGroupInfo.VersionedResourcesStorageMap[hiextensionsv1alpha1.SchemeGroupVersion.Version] = hiextensionv1alphaStorages
		if err := s.GenericAPIServer.InstallAPIGroup(&hiextensionv1alphaApiGroupInfo); err != nil {
			return nil, err
		}
	}

	{
		hinetworkingv1ApiGroupInfo := genericapiserver.NewDefaultAPIGroupInfo(hinetworkingv1.SchemeGroupVersion.Group, Scheme, metav1.ParameterCodec, Codecs)
		hinetworkingv1Storages := map[string]rest.Storage{}
		appendStorage(hinetworkingv1Storages, configClient, hinetworkingv1.SchemeGroupVersion, true, "mcpbridge", "mcpbridges",
			func() runtime.Object { return &hinetworkingv1.McpBridge{} },
			func() runtime.Object { return &hinetworkingv1.McpBridgeList{} },
			nil, nil)
		appendStorage(hinetworkingv1Storages, configClient, hinetworkingv1.SchemeGroupVersion, true, "http2rpc", "http2rpcs",
			func() runtime.Object { return &hinetworkingv1.Http2Rpc{} },
			func() runtime.Object { return &hinetworkingv1.Http2RpcList{} },
			nil, nil)
		hinetworkingv1ApiGroupInfo.VersionedResourcesStorageMap[hinetworkingv1.SchemeGroupVersion.Version] = hinetworkingv1Storages
		if err := s.GenericAPIServer.InstallAPIGroup(&hinetworkingv1ApiGroupInfo); err != nil {
			return nil, err
		}
	}

	return s, nil
}

func appendStorage(storages map[string]rest.Storage,
	configClient config_client.IConfigClient,
	groupVersion schema.GroupVersion,
	isNamespaced bool,
	singularName string,
	pluralName string,
	newFunc func() runtime.Object,
	newListFunc func() runtime.Object,
	attrFunc genericstorage.AttrFunc,
	encryptionKey []byte) {
	groupVersionResource := groupVersion.WithResource(pluralName).GroupResource()
	codec, _, err := genericserverstorage.NewStorageCodec(genericserverstorage.StorageCodecConfig{
		StorageMediaType:  contentType,
		StorageSerializer: serializer.NewCodecFactory(Scheme),
		StorageVersion:    Scheme.PrioritizedVersionsForGroup(groupVersionResource.Group)[0],
		MemoryVersion:     Scheme.PrioritizedVersionsForGroup(groupVersionResource.Group)[0],
		Config:            storagebackend.Config{}, // useless fields..
	})
	if err != nil {
		err = fmt.Errorf("unable to create REST storage for a resource due to %v, will die", err)
		panic(err)
	}
	storages[pluralName] = registry.NewNacosREST(groupVersionResource, codec, configClient, isNamespaced, singularName, newFunc, newListFunc, attrFunc, encryptionKey)
}
