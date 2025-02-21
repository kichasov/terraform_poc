resource "helm_release" "cert-manager" {
  name = "cert-manager"

  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  # version          = "1.17.0"
  set {
    name  = "prometheus.enabled"
    value = "true"
  }
  set {
    name  = "crds.enabled"
    value = "true"
  }
}

resource "helm_release" "cassandra-operator" {
  name = "cassandra"
  repository       = "https://helm.k8ssandra.io"
  chart            = "k8ssandra-operator"
  namespace        = "cassandra"
  create_namespace = true
  # version          = "1.21.1"
  depends_on = [helm_release.cert-manager]
}

resource "time_sleep" "wait_cassandra_operator_to_settle" {
  depends_on      = [helm_release.cassandra-operator]
  create_duration = "5s"
}

resource "null_resource" "cassandra_db" {
  depends_on = [helm_release.cassandra-operator]
  provisioner "local-exec" {
    command = "kubectl -n cassandra apply -f ./var/cassandra_cr.yaml"
    }
  provisioner "local-exec" {
    command = "kubectl wait --for=condition=CassandraInitialized K8ssandraCluster/cassandra -n cassandra --timeout=300s"
    }
}

data "kubernetes_secret" "cassandra_creds" {
  depends_on = [null_resource.cassandra_db]
  metadata {
    name      = "cassandra-superuser"
    namespace = "cassandra"
  }
}

resource "helm_release" "jaeger" {
  name             = "jaeger"
  repository       = "https://ildarminaev.github.io/jaeget-helm-test"
  chart            = "qubership-jaeger"
  namespace        = "jaeger"
  create_namespace = true
  depends_on       = [null_resource.cassandra_db]
  timeout          = "900"
  set {
    name  = "CASSANDRA_SVC"
    value = "cassandra-dc1-service.cassandra.svc.cluster.local"
  }
  set {
    name  = "jaeger.prometheusMonitoringDashboard"
    value = "false"
  }
  set {
    name  = "query.ingress.install"
    value = "true"
  }
  set {
    name  = "query.ingress.host"
    value = "query.jaeger.k8s.home"
  }
  set {
    name  = "cassandraSchemaJob.host"
    value = "cassandra-dc1-service.cassandra.svc.cluster.local"
  }
  set {
    name  = "cassandraSchemaJob.username"
    value = data.kubernetes_secret.cassandra_creds.data["username"]
  }
  set {
    name  = "cassandraSchemaJob.password"
    value = data.kubernetes_secret.cassandra_creds.data["password"]
  }
  set {
    name  = "cassandraSchemaJob.datacenter"
    value = "dc1"
  }
  set {
    name  = "jaeger.prometheusMonitoringDashboard"
    value = "false" 
  }
  set {
    name  = "jaeger.prometheusMonitoring"
    value = "false"
  }
    set {
    name  = "readinessProbe.resources.limits.memory"
    value = "200Mi"
  }
    set {
    name  = "readinessProbe.resources.limits.cpu"
    value = "200m"
  }
    set {
    name  = "readinessProbe.resources.requests.memory"
    value = "100Mi"
  }
    set {
    name  = "readinessProbe.resources.requests.cpu"
    value = "100m"
  }
}

resource "helm_release" "open-telemetry" {
  name             = "open-telemetry"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry"
  create_namespace = true
  depends_on       = [helm_release.cert-manager]
  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-contrib"
  }
  set {
    name  = "manager.extraArgs"
    value = "{--enable-go-instrumentation=true,--enable-nginx-instrumentation=true}"
  }
}

resource "null_resource" "otel" {
  depends_on       = [helm_release.open-telemetry]
  provisioner "local-exec" {
    command = "kubectl create ns business-app"
    }
  provisioner "local-exec" {
    command = "kubectl -n business-app apply -f ./var/collector.yaml"
    }
  provisioner "local-exec" {
    command = "kubectl -n business-app apply -f ./var/instrumentation.yaml"
    }
}

resource "null_resource" "test-app" {
  depends_on       = [null_resource.otel]
  provisioner "local-exec" {
    command = "kubectl -n business-app apply -f ./var/test-deploy.yaml"
    }
#  provisioner "local-exec" {
#    command = "kubectl patch deploy -n business-app test-app -p '{"spec": {"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"true"}}}}}'"    
#    }
}

resource "kubernetes_annotations" "patch_test-app" {
  depends_on = [null_resource.test-app]
  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name = "test-app"
    namespace = "business-app"
  }
  template_annotations = {
    "instrumentation.opentelemetry.io/inject-java" = "true"
  }

  force = true
}
