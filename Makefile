.PHONY: help install install-local install-gcp install-deps check-env check-deps check-gcp uninstall clean check-prereqs setup-repos clean-gcp

# Default environment (local or gcp)
ENV ?= local
# Default container runtime (docker or cri)
RUNTIME ?= docker

REGION ?= us-east1

BLUE := \033[36m
GREEN := \033[32m
RED := \033[31m
YELLOW := \033[33m
RESET := \033[0m

REQUIRED_TOOLS := helm kubectl
HELM_VERSION := $(shell helm version --short 2>/dev/null)
KUBECTL_VERSION := $(shell kubectl version --client --short 2>/dev/null)

##@ General
help:
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Installation
install: check-deps
	@echo "$(BLUE)Installing LGTM stack for $(ENV) environment...$(RESET)"
	@if [ "$(ENV)" = "gcp" ]; then \
		make install-gcp; \
	else \
		make install-local; \
	fi

check-prereqs:
	@echo "Checking prerequisites..."
	@for tool in $(REQUIRED_TOOLS) ; do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			echo "❌ $$tool is not installed" ; \
			exit 1 ; \
		else \
			echo "✅ $$tool is installed" ; \
		fi \
	done
	@if echo "$(HELM_VERSION)" | grep -Eq "^v(3|4)"; then \
        echo "✅ Helm v3+ verified" ; \
    else \
        echo "❌ Helm v3+ is required" ; \
        exit 1 ; \
	fi
	@echo "✅ All prerequisites met!"

setup-repos: check-prereqs
	@echo "Setting up Helm repositories..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update
	kubectl create ns monitoring 2>/dev/null || true
	@echo "✅ Repositories configured"

install-local: setup-repos ## Install LGTM stack for local development
	@echo "$(BLUE)Installing LGTM stack locally...$(RESET)"
	helm install prometheus-operator --version 66.3.1 -n monitoring \
		prometheus-community/kube-prometheus-stack -f helm/values-prometheus.yaml >/dev/null
	helm install lgtm --version 2.1.0 -n monitoring \
		grafana/lgtm-distributed -f helm/values-lgtm.local.yaml >/dev/null
	@make install-deps
	@echo "$(GREEN)LGTM stack installed successfully for local environment!$(RESET)"
	@echo "$(YELLOW)Waiting for Grafana secret to be ready...$(RESET)"
	@until kubectl get secret --namespace monitoring lgtm-grafana -o jsonpath="{.data.admin-password}" >/dev/null 2>&1; do \
		sleep 5; \
	done
	@echo "$(YELLOW)Run 'kubectl port-forward svc/lgtm-grafana 3000:80 -n monitoring' to access Grafana$(RESET)"
	@echo "$(YELLOW)For grafana password run: make get-grafana-password$(RESET)"


install-gcp: setup-repos check-gcp ## Install LGTM stack in GCP
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "❌ PROJECT_ID is not set. Use: export PROJECT_ID=your-project-id" ; \
		exit 1 ; \
	fi
	@echo "$(BLUE)Installing LGTM stack on GCP for project $(PROJECT_ID)...$(RESET)"
	@echo "$(BLUE)Creating GCP resources...$(RESET)"
	$(eval BUCKET_SUFFIX := $(shell openssl rand -hex 4))
	@for bucket in logs traces metrics metrics-admin; do \
		gsutil mb -p $(PROJECT_ID) -c standard -l us-east1 gs://lgtm-$$bucket-$(BUCKET_SUFFIX) ; \
	done
	@sed -i -E "s/(bucket_name:\s*lgtm-[^[:space:]]+)/\1-$(BUCKET_SUFFIX)/g" helm/values-lgtm.gcp.yaml
	@gcloud iam service-accounts create lgtm-monitoring \
		--display-name "LGTM Monitoring" \
		--project $(PROJECT_ID) 2>/dev/null || true
	@for bucket in logs traces metrics metrics-admin; do \
		gsutil iam ch serviceAccount:lgtm-monitoring@$(PROJECT_ID).iam.gserviceaccount.com:admin \
			gs://lgtm-$$bucket-$(BUCKET_SUFFIX) ; \
	done
	@gcloud iam service-accounts keys create key.json \
		--iam-account lgtm-monitoring@$(PROJECT_ID).iam.gserviceaccount.com
	kubectl create secret generic lgtm-sa --from-file=key.json -n monitoring
	helm install prometheus-operator --version 66.3.1 -n monitoring \
		prometheus-community/kube-prometheus-stack -f helm/values-prometheus.yaml >/dev/null
	helm install lgtm --version 2.1.0 -n monitoring \
		grafana/lgtm-distributed -f helm/values-lgtm.gcp.yaml >/dev/null
	@make install-deps
	@echo "$(GREEN)LGTM stack installed successfully in GCP!$(RESET)"
	@echo "$(YELLOW)Run 'kubectl port-forward svc/lgtm-grafana 3000:80 -n monitoring' to access Grafana$(RESET)"
	@echo "$(YELLOW)For grafana password run: make get-grafana-password$(RESET)"

install-deps: ## Install dependencies (promtail & dashboards)
	@echo "$(BLUE)Installing dependencies...$(RESET)"
	@echo "$(BLUE)Installing Promtail for $(RUNTIME) runtime...$(RESET)"
	@if [ "$(RUNTIME)" = "cri" ]; then \
		kubectl apply -f manifests/promtail.cri.yaml ; \
	elif [ "$(RUNTIME)" = "docker" ]; then \
		kubectl apply -f manifests/promtail.docker.yaml ; \
	else \
		echo "$(RED)Invalid runtime. Use RUNTIME=docker or RUNTIME=cri$(RESET)" && exit 1; \
	fi
	@echo "✅ Dependencies installed"

##@ Validation
check-deps: ## Check if required tools are installed
	@echo "$(BLUE)Checking dependencies...$(RESET)"
	@which kubectl >/dev/null || (echo "$(RED)kubectl is required but not installed$(RESET)" && exit 1)
	@which helm >/dev/null || (echo "$(RED)helm is required but not installed$(RESET)" && exit 1)
	@echo "$(GREEN)All dependencies are installed!$(RESET)"

check-gcp: ## Check GCP requirements
	@echo "$(BLUE)Checking GCP requirements...$(RESET)"
	@which gcloud >/dev/null || (echo "$(RED)gcloud CLI is required but not installed$(RESET)" && exit 1)
	@test -n "$(PROJECT_ID)" || (echo "$(RED)GCP project ID is required. Set with PROJECT_ID=your-project-id$(RESET)" && exit 1)
	@echo "$(GREEN)GCP requirements met!$(RESET)"

##@ Cleanup
uninstall: ## Uninstall LGTM stack and dependencies
	@echo "$(BLUE)Uninstalling LGTM stack...$(RESET)"
	helm uninstall lgtm -n monitoring || true
	helm uninstall prometheus-operator -n monitoring || true
	kubectl delete -f manifests/promtail.yaml || true
	kubectl delete -f manifests/otel-collector.yaml || true
	kubectl delete ns monitoring || true

	@if [ "$(ENV)" = "gcp" ]; then \
		echo "$(BLUE)Cleaning up GCP resources...$(RESET)"; \
		for bucket in logs traces metrics metrics-admin; do \
			gsutil rm -r gs://lgtm-$$bucket-* || true; \
		done; \
		gcloud iam service-accounts delete lgtm-monitoring@$(PROJECT_ID).iam.gserviceaccount.com --quiet || true; \
	fi

	@echo "$(GREEN)Uninstallation complete!$(RESET)"

clean: uninstall ## Alias for uninstall

get-grafana-password:
	@kubectl get secret --namespace monitoring lgtm-grafana -o jsonpath="{.data.admin-password}" | base64 --decode

clean-gcp:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "❌ PROJECT_ID is not set. Use: export PROJECT_ID=your-project-id" ; \
		exit 1 ; \
	fi
	@if [ -z "$(BUCKET_SUFFIX)" ]; then \
		echo "❌ BUCKET_SUFFIX is not set. This is required for cleanup" ; \
		exit 1 ; \
	fi
	@echo "Cleaning up GCP resources..."
	helm uninstall lgtm -n monitoring || true
	helm uninstall prometheus-operator -n monitoring || true
	kubectl delete ns monitoring || true
	@for bucket in logs traces metrics metrics-admin; do \
		gsutil rm -r gs://lgtm-$$bucket-$(BUCKET_SUFFIX) || true ; \
	done
	gcloud iam service-accounts delete lgtm-monitoring@$(PROJECT_ID).iam.gserviceaccount.com || true
	@echo "✅ GCP resources cleaned up"
