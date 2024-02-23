package codec

import (
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer/json"
	"k8s.io/apimachinery/pkg/runtime/serializer/versioning"
)

type legacyNegotiatedSerializer struct {
	scheme  *runtime.Scheme
	accepts []runtime.SerializerInfo
}

func CreateLegacyNegotiatedSerializer(scheme *runtime.Scheme) runtime.NegotiatedSerializer {
	mf := json.DefaultMetaFactory
	jsonSerializer := json.NewSerializerWithOptions(
		mf, scheme, scheme,
		json.SerializerOptions{Yaml: false, Pretty: false, Strict: false},
	)
	prettyJsonSerializer := json.NewSerializerWithOptions(
		mf, scheme, scheme,
		json.SerializerOptions{Yaml: false, Pretty: true, Strict: false},
	)
	strictJsonSerializer := json.NewSerializerWithOptions(
		mf, scheme, scheme,
		json.SerializerOptions{Yaml: false, Pretty: false, Strict: true},
	)
	yamlSerializer := json.NewSerializerWithOptions(
		mf, scheme, scheme,
		json.SerializerOptions{Yaml: true, Pretty: false, Strict: false},
	)
	strictYamlSerializer := json.NewSerializerWithOptions(
		mf, scheme, scheme,
		json.SerializerOptions{Yaml: true, Pretty: false, Strict: true},
	)
	return &legacyNegotiatedSerializer{
		scheme: scheme,
		accepts: []runtime.SerializerInfo{
			{
				MediaType:        "application/json",
				MediaTypeType:    "application",
				MediaTypeSubType: "json",
				EncodesAsText:    true,
				Serializer:       jsonSerializer,
				PrettySerializer: prettyJsonSerializer,
				StrictSerializer: strictJsonSerializer,
				StreamSerializer: &runtime.StreamSerializerInfo{
					Serializer:    jsonSerializer,
					EncodesAsText: true,
					Framer:        json.Framer,
				},
			},
			{
				MediaType:        "application/yaml",
				MediaTypeType:    "application",
				MediaTypeSubType: "yaml",
				EncodesAsText:    true,
				Serializer:       yamlSerializer,
				StrictSerializer: strictYamlSerializer,
			},
		},
	}
}

func (l *legacyNegotiatedSerializer) SupportedMediaTypes() []runtime.SerializerInfo {
	return l.accepts
}

func (l *legacyNegotiatedSerializer) EncoderForVersion(encoder runtime.Encoder, gv runtime.GroupVersioner) runtime.Encoder {
	return versioning.NewDefaultingCodecForScheme(l.scheme, encoder, nil, gv, nil)
}

func (l *legacyNegotiatedSerializer) DecoderToVersion(decoder runtime.Decoder, gv runtime.GroupVersioner) runtime.Decoder {
	return versioning.NewDefaultingCodecForScheme(l.scheme, nil, decoder, nil, gv)
}
