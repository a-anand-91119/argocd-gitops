To revert the changes
---

Remove the services
```shell
kubectl delete service felix-metrics-svc -n calico-system
kubectl delete service typha-metrics-svc -n calico-system
```

Return Calico configurations to their default state.
```shell
kubectl patch felixConfiguration default --type merge --patch '{"spec":{"prometheusMetricsEnabled": false}}'
kubectl patch installation default --type=json -p '[{"op": "remove", "path":"/spec/typhaMetricsPort"}]'
```

Finally, remove the namespace and RBAC permissions.
```shell
kubectl delete namespace calico-monitoring
kubectl delete ClusterRole calico-prometheus-user
kubectl delete clusterrolebinding calico-prometheus-user
```
