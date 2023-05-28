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
	"github.com/spf13/cobra"
	"io"
	utilerrors "k8s.io/apimachinery/pkg/util/errors"
	"k8s.io/apiserver/pkg/endpoints/openapi"
	"k8s.io/apiserver/pkg/features"
	genericapiserver "k8s.io/apiserver/pkg/server"
	genericoptions "k8s.io/apiserver/pkg/server/options"
	utilfeature "k8s.io/apiserver/pkg/util/feature"
	"k8s.io/client-go/informers"
	openapicommon "k8s.io/kube-openapi/pkg/common"
	"k8s.io/sample-apiserver/pkg/apiserver"
	"k8s.io/sample-apiserver/pkg/options"
	netutils "k8s.io/utils/net"
	"net"
)

// HigressServerOptions contains state for master/api server
type HigressServerOptions struct {
	RecommendedOptions *genericoptions.RecommendedOptions
	NacosOptions       *options.NacosOptions

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
		NacosOptions: &options.NacosOptions{},
		StdOut:       out,
		StdErr:       errOut,
	}
	return o
}

// Validate validates HigressServerOptions
func (o HigressServerOptions) Validate(args []string) error {
	errors := []error{}
	errors = append(errors, validate(o.RecommendedOptions)...)
	errors = append(errors, o.NacosOptions.Validate()...)
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

		"k8s.io/api/admissionregistration/v1.MutatingWebhookConfiguration":   {},
		"k8s.io/api/admissionregistration/v1.ValidatingWebhookConfiguration": {},

		"k8s.io/api/networking/v1.Ingress":      {},
		"k8s.io/api/networking/v1.IngressClass": {},

		"github.com/alibaba/higress/client/pkg/apis/extensions/v1alpha1.WasmPlugin": {},
		"github.com/alibaba/higress/client/pkg/apis/networking/v1.McpBridge":        {},
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

	if utilfeature.DefaultFeatureGate.Enabled(features.OpenAPIV3) {
		serverConfig.OpenAPIV3Config = genericapiserver.DefaultOpenAPIV3Config(getOpenAPIDefinitions, openapi.NewDefinitionNamer(apiserver.Scheme))
		serverConfig.OpenAPIV3Config.Info.Title = "Higress"
		serverConfig.OpenAPIV3Config.Info.Version = "0.1"
	}

	// TODO: AuthZ and AuthN are not ready yet.
	o.RecommendedOptions.Authentication = nil
	o.RecommendedOptions.Authorization = nil

	if err := applyTo(o.RecommendedOptions, serverConfig); err != nil {
		return nil, err
	}

	config := &apiserver.Config{
		GenericConfig: serverConfig,
		ExtraConfig: apiserver.ExtraConfig{
			NacosOptions: o.NacosOptions,
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

func applyTo(o *genericoptions.RecommendedOptions, config *genericapiserver.RecommendedConfig) error {
	if err := o.EgressSelector.ApplyTo(&config.Config); err != nil {
		return err
	}
	if err := o.Traces.ApplyTo(config.Config.EgressSelector, &config.Config); err != nil {
		return err
	}
	if err := o.SecureServing.ApplyTo(&config.Config.SecureServing, &config.Config.LoopbackClientConfig); err != nil {
		return err
	}
	if err := o.Authentication.ApplyTo(&config.Config.Authentication, config.SecureServing, config.OpenAPIConfig); err != nil {
		return err
	}
	if err := o.Authorization.ApplyTo(&config.Config.Authorization); err != nil {
		return err
	}
	if err := o.Audit.ApplyTo(&config.Config); err != nil {
		return err
	}
	if err := o.Features.ApplyTo(&config.Config); err != nil {
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
	o.NacosOptions.AddFlags(flags)
	utilfeature.DefaultMutableFeatureGate.AddFlag(flags)

	return cmd
}
