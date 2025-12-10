#!/bin/bash
# Quick environment switcher for multiple Minikube profiles

ENV=$1

if [ -z "$ENV" ]; then
    echo "Usage: ./switch-env.sh <profile-name>"
    echo ""
    echo "Default profile: keycloak-vault"
    echo ""
    echo "Available profiles:"
    minikube profile list
    echo ""
    echo "Current profile: $(minikube profile)"
    exit 1
fi

# Switch profile
echo "Switching to profile: $ENV"
minikube profile $ENV

# Show status
echo ""
echo "Status:"
minikube status

# Show kubectl context
echo ""
echo "kubectl context: $(kubectl config current-context)"
echo ""
echo "To deploy, run: ./deploy-all.sh"
