###############################################
# Reference notes:
# https://cloud.google.com/solutions/continuous-delivery-spinnaker-kubernetes-engine?refresh=1
# https://github.com/stefanprodan/istio-gke 
# https://rinormaloku.com/series/istio-around-everything-else/ 
###############################################



k8s_version=$(gcloud container get-server-config --region=us-central1 --format=json \
| jq -r '.validNodeVersions[0]')

gcloud container clusters create istio \
--cluster-version=${k8s_version} \
--zone=us-central1-a \
--num-nodes=4 \
--machine-type=n1-standard-2 \
--preemptible \
--enable-autorepair \
--scopes=gke-default

gcloud container clusters get-credentials istio -z=us-central1-a


gcloud dns managed-zones create \
--dns-name="kubernetesclustertest.com." \
--description="Istio zone" "istio"

gcloud dns managed-zones describe istio

watch dig +short NS kubernetesclustertest.com

gcloud compute addresses create istio-gateway-ip --region us-central1

gcloud compute addresses describe istio-gateway-ip --region us-central1

DOMAIN="kubernetesclustertest.com"
## Run this first to get clusterIP GATEWAYIP=gcloud compute addresses describe istio-gateway-ip --region us-central1
GATEWAYIP=<CLUSTER_IP>

gcloud dns record-sets transaction start --zone=istio

gcloud dns record-sets transaction add --zone=istio \
--name="${DOMAIN}" --ttl=300 --type=A ${GATEWAYIP}

gcloud dns record-sets transaction add --zone=istio \
--name="www.${DOMAIN}" --ttl=300 --type=A ${GATEWAYIP}

gcloud dns record-sets transaction add --zone=istio \
--name="*.${DOMAIN}" --ttl=300 --type=A ${GATEWAYIP}

gcloud dns record-sets transaction execute --zone istio

watch host test.kubernetesclustertest.com

kubectl --namespace kube-system create sa tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
./helm init --service-account tiller --upgrade --wait

export ISTIO_VER="1.2.0"

helm repo add istio.io https://storage.googleapis.com/istio-release/releases/${ISTIO_VER}/charts
helm upgrade -i istio-init istio.io/istio-init --wait --namespace istio-system

kubectl -n istio-system wait --for=condition=complete job/istio-init-crd-10
kubectl -n istio-system wait --for=condition=complete job/istio-init-crd-11
kubectl -n istio-system wait --for=condition=complete job/istio-init-crd-12

# generate a random password
PASSWORD=$(head -c 12 /dev/urandom | shasum| cut -d' ' -f1)

kubectl -n istio-system create secret generic grafana \
--from-literal=username=admin \
--from-literal=passphrase="$PASSWORD"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: kiali
  namespace: istio-system
  labels:
    app: kiali
type: Opaque
data:
  username: YWRtaW4=
  passphrase: YWRtaW4=
EOF

helm upgrade --install istio istio.io/istio \
--namespace=istio-system \
-f ./my-istio.yaml

watch kubectl -n istio-system get pods

kubectl apply -f ./istio-gateway.yaml

GCP_PROJECT=gke-istio-spinnaker-cloud

gcloud iam service-accounts create dns-admin \
--display-name=dns-admin \
--project=${GCP_PROJECT}

gcloud iam service-accounts keys create ./gcp-dns-admin.json \
--iam-account=dns-admin@${GCP_PROJECT}.iam.gserviceaccount.com \
--project=${GCP_PROJECT}

gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
--member=serviceAccount:dns-admin@${GCP_PROJECT}.iam.gserviceaccount.com \
--role=roles/dns.admin

kubectl create secret generic cert-manager-credentials \
--from-file=./gcp-dns-admin.json \
--namespace=istio-system

CERT_REPO=https://raw.githubusercontent.com/jetstack/cert-manager

kubectl apply -f ${CERT_REPO}/release-0.7/deploy/manifests/00-crds.yaml

kubectl create namespace cert-manager

kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true

./helm repo add jetstack https://charts.jetstack.io && \
./helm repo update && \
./helm upgrade -i cert-manager \
--namespace cert-manager \
--version v0.7.0 \
jetstack/cert-manager

kubectl apply -f ./letsencrypt-issuer.yaml

kubectl apply -f ./of-cert.yaml

kubectl -n istio-system describe certificate istio-gateway

gcloud iam service-accounts create  spinnaker-account \
    --display-name spinnaker-account

export SA_EMAIL=$(gcloud iam service-accounts list \
    --filter="displayName:spinnaker-account" \
    --format='value(email)')
export PROJECT=$(gcloud info --format='value(config.project)')

gcloud projects add-iam-policy-binding \
    $PROJECT --role roles/storage.admin --member serviceAccount:$SA_EMAIL

gcloud iam service-accounts keys create spinnaker-sa.json --iam-account $SA_EMAIL

gcloud beta pubsub topics create projects/$PROJECT/topics/gcr

gcloud beta pubsub subscriptions create gcr-triggers \
    --topic projects/${PROJECT}/topics/gcr

export SA_EMAIL=$(gcloud iam service-accounts list \
    --filter="displayName:spinnaker-account" \
    --format='value(email)')
gcloud beta pubsub subscriptions add-iam-policy-binding gcr-triggers \
    --role roles/pubsub.subscriber --member serviceAccount:$SA_EMAIL

kubectl create clusterrolebinding --clusterrole=cluster-admin --serviceaccount=default:default spinnaker-admin

export PROJECT=$(gcloud info \
    --format='value(config.project)')
export BUCKET=$PROJECT-spinnaker-config
gsutil mb -c regional -l us-central1 gs://$BUCKET

export SA_JSON=$(cat spinnaker-sa.json)
export PROJECT=$(gcloud info --format='value(config.project)')
export BUCKET=$PROJECT-spinnaker-config
cat > spinnaker-config.yaml <<EOF
gcs:
  enabled: true
  bucket: $BUCKET
  project: $PROJECT
  jsonKey: '$SA_JSON'

dockerRegistries:
- name: gcr
  address: https://gcr.io
  username: _json_key
  password: '$SA_JSON'
  email: 1234@5678.com

# Disable minio as the default storage backend
minio:
  enabled: false

# Configure Spinnaker to enable GCP services
halyard:
  spinnakerVersion: 1.10.2
  image:
    tag: 1.12.0
  additionalScripts:
    create: true
    data:
      enable_gcs_artifacts.sh: |-
        \$HAL_COMMAND config artifact gcs account add gcs-$PROJECT --json-path /opt/gcs/key.json
        \$HAL_COMMAND config artifact gcs enable
      enable_pubsub_triggers.sh: |-
        \$HAL_COMMAND config pubsub google enable
        \$HAL_COMMAND config pubsub google subscription add gcr-triggers \
          --subscription-name gcr-triggers \
          --json-path /opt/gcs/key.json \
          --project $PROJECT \
          --message-format GCR
EOF

kubectl label namespace default istio-injection=enabled

./helm install -n cd stable/spinnaker -f spinnaker-config.yaml --timeout 600 \
    --version 1.1.6 --wait

# Have to edit spin-gate deployment manifest to use tcp readiness check
# https://github.com/spinnaker/spinnaker/issues/2765#issuecomment-397171924

# NOTE: do not put hyphens in the host field... It wont work

# May "fail" based on a timeout
gcloud sql instances create application-relational-datastore --tier=db-f1-micro --region=us-central1

gcloud sql users set-password root \
    --host=% --instance=application-relational-datastore --prompt-for-password

cloud sql users create demo-user    --host=% --instance=application-relational-datastore --password=Foo1234

gcloud iam service-accounts create cloud-sql-account \
    --display-name cloud-sql-account

export SA_EMAIL=$(gcloud iam service-accounts list \
    --filter="displayName:cloud-sql-account" \
    --format='value(email)')
export PROJECT=$(gcloud info --format='value(config.project)')

gcloud projects add-iam-policy-binding \
    $PROJECT --role roles/editor --member serviceAccount:$SA_EMAIL

gcloud iam service-accounts keys create cloud-sql-sa.json --iam-account $SA_EMAIL

kubectl create secret generic cloudsql-oauth-credentials --from-file=credentials.json=cloud-sql-sa.json

kubectl create secret generic demo-db-password --from-literal=spring.datasource.username=demo-user --from-literal=spring.datasource.password=Foo1234

