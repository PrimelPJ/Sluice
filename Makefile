.PHONY: help install test lint build fmt plan apply destroy smoke trigger clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

install: ## Install dev dependencies
	pip install -r requirements-dev.txt

test: ## Run unit tests
	PYTHONPATH=src python -m pytest tests/ -q

lint: ## Static checks
	PYTHONPATH=src python -m pyflakes src tests || true
	python -m py_compile $$(find src -name '*.py')

build: ## Stage the Lambda layer for Terraform to package
	./scripts/package_lambdas.sh

fmt: ## Format Terraform
	cd infra && terraform fmt -recursive

plan: build ## terraform plan
	cd infra && terraform init -input=false && terraform plan

apply: build ## terraform apply
	cd infra && terraform init -input=false && terraform apply

destroy: ## Tear everything down
	cd infra && terraform destroy

smoke: ## Curl the deployed API
	./scripts/smoke_test.sh

trigger: ## Drive one manual end-to-end cycle
	./scripts/trigger_pipeline.sh

clean: ## Remove build artifacts
	rm -rf build .pytest_cache $$(find . -name __pycache__ -type d)
