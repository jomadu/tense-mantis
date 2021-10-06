https://kind.sigs.k8s.io/docs/user/ingress/
kind create cluster --config cluster-config.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
kubectl apply -f ingress-deployment.yaml
kubectl apply -f backend/backend-manifest.yaml
hit up localhost

https://kind.sigs.k8s.io/docs/user/loadbalancer/
kind create cluster
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml
docker network inspect -f '{{.IPAM.Config}}' kind
kubectl apply -f metallb-configmap.yaml
