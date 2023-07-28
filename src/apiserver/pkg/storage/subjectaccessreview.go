package storage

import (
	"context"
	authzv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apiserver/pkg/registry/rest"
)

type SubjectAccessReviewStorage struct {
}

func (s *SubjectAccessReviewStorage) NamespaceScoped() bool {
	return false
}

func (s *SubjectAccessReviewStorage) GetSingularName() string {
	return "subjectaccessreview"
}

func (s *SubjectAccessReviewStorage) New() runtime.Object {
	return &authzv1.SubjectAccessReview{}
}

func (s *SubjectAccessReviewStorage) Destroy() {
}

func (s *SubjectAccessReviewStorage) Create(ctx context.Context,
	obj runtime.Object,
	createValidation rest.ValidateObjectFunc,
	options *metav1.CreateOptions,
) (runtime.Object, error) {
	if createValidation != nil {
		if err := createValidation(ctx, obj); err != nil {
			return nil, err
		}
	}

	// Always allow
	result := &authzv1.SubjectAccessReview{
		Status: authzv1.SubjectAccessReviewStatus{
			Allowed: true,
		},
	}
	return result, nil
}
