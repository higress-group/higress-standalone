package storage

import (
	"context"
	"embed"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/apiserver/pkg/registry/rest"
)

var (
	//go:embed crds
	res embed.FS

	groupResource = apiextensionsv1.Resource("customresourcedefinitions")
)

func CreateCustomResourceDefinitionStorage(codec runtime.Codec) (rest.Storage, error) {
	crds := make([]apiextensionsv1.CustomResourceDefinition, 0)
	files, err := res.ReadDir("crds")
	if err != nil {
		return nil, err
	}
	for _, file := range files {
		content, err := res.ReadFile("crds/" + file.Name())
		if err != nil {
			return nil, err
		}
		crd, _, err := codec.Decode(content, nil, &apiextensionsv1.CustomResourceDefinition{})
		if err != nil {
			return nil, err
		}
		crds = append(crds, *(crd.(*apiextensionsv1.CustomResourceDefinition)))
	}
	return &customResourceDefinitionStorage{crds: crds}, nil
}

type customResourceDefinitionStorage struct {
	rest.TableConvertor
	crds []apiextensionsv1.CustomResourceDefinition
}

func (s *customResourceDefinitionStorage) NamespaceScoped() bool {
	return false
}

func (s *customResourceDefinitionStorage) GetSingularName() string {
	return "customresourcedefinition"
}

func (s *customResourceDefinitionStorage) New() runtime.Object {
	return &apiextensionsv1.CustomResourceDefinition{}
}

func (s *customResourceDefinitionStorage) Destroy() {
}

func (s *customResourceDefinitionStorage) Get(
	ctx context.Context,
	name string,
	options *metav1.GetOptions,
) (runtime.Object, error) {
	for _, crd := range s.crds {
		if crd.Name == name {
			return &crd, nil
		}
	}
	return nil, apierrors.NewNotFound(groupResource, name)
}

func (s *customResourceDefinitionStorage) NewList() runtime.Object {
	return &apiextensionsv1.CustomResourceDefinitionList{}
}

func (s *customResourceDefinitionStorage) List(
	ctx context.Context,
	options *metainternalversion.ListOptions,
) (runtime.Object, error) {
	return &apiextensionsv1.CustomResourceDefinitionList{Items: s.crds}, nil
}

func (s *customResourceDefinitionStorage) Create(
	ctx context.Context,
	obj runtime.Object,
	createValidation rest.ValidateObjectFunc,
	options *metav1.CreateOptions,
) (runtime.Object, error) {
	return nil, apierrors.NewServiceUnavailable("create operation is not supported")
}

func (s *customResourceDefinitionStorage) Update(
	ctx context.Context,
	name string,
	objInfo rest.UpdatedObjectInfo,
	createValidation rest.ValidateObjectFunc,
	updateValidation rest.ValidateObjectUpdateFunc,
	forceAllowCreate bool,
	options *metav1.UpdateOptions,
) (runtime.Object, bool, error) {
	return nil, false, apierrors.NewServiceUnavailable("update operation is not supported")
}

func (s *customResourceDefinitionStorage) Delete(
	ctx context.Context,
	name string,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions) (runtime.Object, bool, error) {
	return nil, false, apierrors.NewServiceUnavailable("delete operation is not supported")
}

func (s *customResourceDefinitionStorage) DeleteCollection(
	ctx context.Context,
	deleteValidation rest.ValidateObjectFunc,
	options *metav1.DeleteOptions,
	listOptions *metainternalversion.ListOptions,
) (runtime.Object, error) {
	return nil, apierrors.NewServiceUnavailable("deleteCollection operation is not supported")
}

func (s *customResourceDefinitionStorage) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	return watch.NewFake(), nil
}
