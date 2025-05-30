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

package server

import (
	"fmt"
	"io"
	"net"

	"github.com/spf13/cobra"
	utilerrors "k8s.io/apimachinery/pkg/util/errors"
	"k8s.io/apiserver/pkg/endpoints/openapi"
	genericapiserver "k8s.io/apiserver/pkg/server"
	genericoptions "k8s.io/apiserver/pkg/server/options"
	utilfeature "k8s.io/apiserver/pkg/util/feature"
	utilversion "k8s.io/apiserver/pkg/util/version"
	"k8s.io/client-go/informers"
	openapicommon "k8s.io/kube-openapi/pkg/common"
	netutils "k8s.io/utils/net"

	"github.com/alibaba/higress/api-server/pkg/apiserver"
	"github.com/alibaba/higress/api-server/pkg/options"
)

// HigressServerOptions contains state for master/api server
type HigressServerOptions struct {
	RecommendedOptions *genericoptions.RecommendedOptions
	AuthOptions        *options.AuthOptions
	StorageOptions     *options.StorageOptions

	SharedInformerFactory informers.SharedInformerFactory
	StdOut                io.Writer
	StdErr                io.Writer

	AlternateDNS []string
}

// NewHigressServerOptions returns a new HigressServerOptions
func NewHigressServerOptions(out, errOut io.Writer) *HigressServerOptions {
	o := &HigressServerOptions{
		RecommendedOptions: genericoptions.NewRecommendedOptions(
			"",
			apiserver.Codecs.LegacyCodec(),
		),
		AuthOptions:    options.CreateAuthOptions(),
		StorageOptions: options.CreateStorageOptions(),
		StdOut:         out,
		StdErr:         errOut,
	}
	return o
}

// Validate validates HigressServerOptions
func (o *HigressServerOptions) Validate(args []string) error {
	errors := []error{}
	errors = append(errors, validate(o.RecommendedOptions)...)
	errors = append(errors, o.AuthOptions.Validate()...)
	errors = append(errors, o.StorageOptions.Validate()...)
	return utilerrors.NewAggregate(errors)
}

// Complete fills in fields required to have valid data
func (o *HigressServerOptions) Complete() error {
	return nil
}

func getOpenAPIDefinitions(openapicommon.ReferenceCallback) map[string]openapicommon.OpenAPIDefinition {
	return map[string]openapicommon.OpenAPIDefinition{
		"k8s.io/api/core/v1.ConfigMap": {},
		"k8s.io/api/core/v1.Secret":    {},
		"k8s.io/api/core/v1.Service":   {},
		"k8s.io/api/core/v1.Endpoints": {},
		"k8s.io/api/core/v1.Pod":       {},
		"k8s.io/api/core/v1.Node":      {},
		"k8s.io/api/core/v1.Namespace": {},

		"k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1.CustomResourceDefinition": {},

		"k8s.io/api/admissionregistration/v1.MutatingWebhookConfiguration":   {},
		"k8s.io/api/admissionregistration/v1.ValidatingWebhookConfiguration": {},

		"k8s.io/api/authorization/v1.SubjectAccessReview": {},

		"k8s.io/api/discovery/v1.EndpointSlice": {},

		"k8s.io/api/networking/v1.Ingress":      {},
		"k8s.io/api/networking/v1.IngressClass": {},

		"github.com/alibaba/higress/client/pkg/apis/extensions/v1alpha1.WasmPlugin": {},
		"github.com/alibaba/higress/client/pkg/apis/networking/v1.McpBridge":        {},
		"github.com/alibaba/higress/client/pkg/apis/networking/v1.Http2Rpc":         {},

		"istio.io/client-go/pkg/apis/networking/v1alpha3.EnvoyFilter": {},

		"github.com/alibaba/higress/api-server/pkg/apis/gatewayapi/v1.GatewayClass":   {},
		"github.com/alibaba/higress/api-server/pkg/apis/gatewayapi/v1.Gateway":        {},
		"github.com/alibaba/higress/api-server/pkg/apis/gatewayapi/v1.HTTPRoute":      {},
		"github.com/alibaba/higress/api-server/pkg/apis/gatewayapi/v1.ReferenceGrant": {},

		"sigs.k8s.io/gateway-api/apis/v1beta1.GatewayClass":    {},
		"sigs.k8s.io/gateway-api/apis/v1beta1.Gateway":         {},
		"sigs.k8s.io/gateway-api/apis/v1beta1.HTTPRoute":       {},
		"sigs.k8s.io/gateway-api/apis/v1beta1.ReferenceGrant":  {},
		"sigs.k8s.io/gateway-api/apis/v1alpha2.GatewayClass":   {},
		"sigs.k8s.io/gateway-api/apis/v1alpha2.Gateway":        {},
		"sigs.k8s.io/gateway-api/apis/v1alpha2.HTTPRoute":      {},
		"sigs.k8s.io/gateway-api/apis/v1alpha2.ReferenceGrant": {},
	}
}

// Config returns config for the api server given HigressServerOptions
func (o *HigressServerOptions) Config() (*apiserver.Config, error) {
	// TODO have a "real" external address
	if err := o.RecommendedOptions.SecureServing.MaybeDefaultWithSelfSignedCerts("localhost", o.AlternateDNS, []net.IP{netutils.ParseIPSloppy("127.0.0.1")}); err != nil {
		return nil, fmt.Errorf("error creating self-signed certificates: %v", err)
	}

	serverConfig := genericapiserver.NewRecommendedConfig(apiserver.Codecs)

	serverConfig.SkipOpenAPIInstallation = true

	serverConfig.OpenAPIConfig = genericapiserver.DefaultOpenAPIConfig(getOpenAPIDefinitions, openapi.NewDefinitionNamer(apiserver.Scheme))
	serverConfig.OpenAPIConfig.Info.Title = "Higress"
	serverConfig.OpenAPIConfig.Info.Version = "0.1"

	serverConfig.OpenAPIV3Config = genericapiserver.DefaultOpenAPIV3Config(getOpenAPIDefinitions, openapi.NewDefinitionNamer(apiserver.Scheme))
	serverConfig.OpenAPIV3Config.Info.Title = "Higress"
	serverConfig.OpenAPIV3Config.Info.Version = "0.1"

	// Set version to 1.19.0 so client can use networking.k8s.io/v1 instead of networking.k8s.io/v1beta1
	serverConfig.EffectiveVersion = utilversion.NewEffectiveVersion("1.19.0")

	o.RecommendedOptions.Authentication.RemoteKubeConfigFileOptional = true
	o.RecommendedOptions.Authorization.RemoteKubeConfigFileOptional = true
	o.RecommendedOptions.Features.EnablePriorityAndFairness = false

	if err := applyTo(o.RecommendedOptions, serverConfig, o.AuthOptions); err != nil {
		return nil, err
	}

	config := &apiserver.Config{
		GenericConfig: serverConfig,
		ExtraConfig: apiserver.ExtraConfig{
			AuthOptions:    o.AuthOptions,
			StorageOptions: o.StorageOptions,
		},
	}
	return config, nil
}

// RunHigressServer starts a new HigressServer given HigressServerOptions
func (o *HigressServerOptions) RunHigressServer(stopCh <-chan struct{}) error {
	config, err := o.Config()
	if err != nil {
		return err
	}

	server, err := config.Complete().New()
	if err != nil {
		return err
	}

	server.GenericAPIServer.AddPostStartHookOrDie("start-higress-server-informers", func(context genericapiserver.PostStartHookContext) error {
		return nil
	})

	return server.GenericAPIServer.PrepareRun().Run(stopCh)
}

func applyTo(o *genericoptions.RecommendedOptions, config *genericapiserver.RecommendedConfig, authOptions *options.AuthOptions) error {
	if err := o.EgressSelector.ApplyTo(&config.Config); err != nil {
		return err
	}
	if err := o.Traces.ApplyTo(config.Config.EgressSelector, &config.Config); err != nil {
		return err
	}
	if err := o.SecureServing.ApplyTo(&config.Config.SecureServing, &config.Config.LoopbackClientConfig); err != nil {
		return err
	}
	if authOptions != nil && authOptions.Enabled {
		if err := o.Authentication.ApplyTo(&config.Config.Authentication, config.SecureServing, config.OpenAPIConfig); err != nil {
			return err
		}
		if err := o.Authorization.ApplyTo(&config.Config.Authorization); err != nil {
			return err
		}
	}
	if err := o.Audit.ApplyTo(&config.Config); err != nil {
		return err
	}
	if err := o.Features.ApplyTo(&config.Config, nil, nil); err != nil {
		return err
	}
	return nil
}

func validate(o *genericoptions.RecommendedOptions) []error {
	errors := []error{}
	errors = append(errors, o.SecureServing.Validate()...)
	errors = append(errors, o.Authentication.Validate()...)
	errors = append(errors, o.Authorization.Validate()...)
	errors = append(errors, o.Audit.Validate()...)
	errors = append(errors, o.Features.Validate()...)
	errors = append(errors, o.EgressSelector.Validate()...)
	errors = append(errors, o.Traces.Validate()...)
	return errors
}

// NewCommandStartHigressServer provides a CLI handler for 'start master' command
// with a default HigressServerOptions.
func NewCommandStartHigressServer(defaults *HigressServerOptions, stopCh <-chan struct{}) *cobra.Command {
	o := *defaults
	cmd := &cobra.Command{
		Short: "Launch a Higress API server",
		Long:  "Launch a Higress API server",
		RunE: func(c *cobra.Command, args []string) error {
			if err := o.Complete(); err != nil {
				return err
			}
			if err := o.Validate(args); err != nil {
				return err
			}
			if err := o.RunHigressServer(stopCh); err != nil {
				return err
			}
			return nil
		},
	}

	flags := cmd.Flags()
	o.RecommendedOptions.AddFlags(flags)
	o.AuthOptions.AddFlags(flags)
	o.StorageOptions.AddFlags(flags)
	utilfeature.DefaultMutableFeatureGate.AddFlag(flags)

	return cmd
}
