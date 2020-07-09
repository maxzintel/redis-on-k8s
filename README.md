# Redis on K8s!
#### Redis is unique, and deploying it is a unique experience.
Read on for why that is, and to learn how to deploy a simple replicated redis cluster.  
Alternatively, read the Redis documentation, as it certainly does a much better job than I will.  
  
### Outline:
* Redis is a popular key/value, in-memory store. People use it as a one-stop-shop caching service.
* Being that Redis deployments are replicated and standalone, it solves some of the traditional problems with server-side caching, namely that clients can connect to any 'server' in the cluster, without us having to worry if it will be the same server that they cached data in previously.
* **Redis is actually two services running in tandem**:
  * `redis-server`: Which implements the actual key/value store (kvs).
  * `redis-sentinel`: Which, like the name implies, implements health checking and failover on the deployment.
* **Deploying Redis in a replicated manner means you are deploying a single Alpha server that is used for read/write ops. There are additional Beta servers that duplicate the data on the Alpha, and load balance read operations.**
  * If the Alpha ever fails/goes down, and one of the Betas can fail over to become the new Alpha. This operation is performed by the sentinel.

### Configuration v2:
**Much of this is exactly the same as bitnami's guide linked below, however I have re-ordered and re-worded it such that it is slightly easier to follow (in my opinion).**
* Alright. So, the config in `~/infra/...` is old. We need a modern way to deploy redis. Helm (https://docs.bitnami.com/tutorials/deploy-redis-sentinel-production-cluster/) seems like a good pick.
* Following along with that tutorial...
  * `curl -Lo values-production.yaml https://raw.githubusercontent.com/bitnami/charts/alpha/bitnami/redis/values-production.yaml` to get the redis chart. We need to edit this to enable sentinel. `CMD+F` Sentinel to find the section where `sentinel.enabled: false` and change it to true.
  * Double check you are connected to the right cluster. `kubectl cluster-info`. If you are, ~nothing to see here~, if you are not, `kubectl config use-context my-cluster-name` should do the trick!
  * Install the latest version of the chart using the yaml file as shown below:
    * `helm repo add bitnami https://charts.bitnami.com/bitnami` then
    * `helm install redis bitnami/redis --values values-production.yaml`, this will output a bunch of stuff we will reference later, see my output in `~/infra-v2/output.txt`
  * Check the status of the Pods and deployment with `kubectl get pods`
  * Congrats! You now have a running redis cluster! Now let's dig into it, testing its features (data replication, failover, etc...).
* Testing Redis cluster data replication:
  * First, we want to connect to the alpha node and save some key and value in the key value store.
  * `kubectl get pods` to get the name of your alpha pod.
  * `kubectl get svc` to get the name of your headless service.
  * `export REDIS_PASSWORD=$(kubectl get secret --namespace default redis -o jsonpath="{.data.redis-password}" | base64 --decode)` to get and save your password in your current terminal instance. You'll have to rerun this if you exit your terminal, restart your machine, etc.
  * Accessing the alpha node requires the above information. Basically, we have to run a redis client in a separate pod, then from that pod connect to the redis alpha. Once we have connected, we can use some commands to save a simple key and value. **The goal of this is to check whether that key/value pair has replicated to the beta instances.**
  * Run Redis in a separate pod as mentioned above: `kubectl run --namespace default redis-client --rm --tty -i --restart='Never' --env REDIS_PASSWORD=$REDIS_PASSWORD --labels="redis-client=true" --image docker.io/bitnami/redis:6.0.5-debian-10-r23 -- bash`
  * In that Pod, connect to the alpha with: `redis-cli -h redis-alpha-0.redis-headless -a $REDIS_PASSWORD`
  * Once you have connected, save a key and value with `set foo "hello world"`.
  * Verify it's saved with `get foo` (should output "hello world").
  * Exit the alpha with `exit`.
  * Connect to a beta Pod (still in your separate redis Pod from before) with `redis-cli -h BETA-POD-NAME.HEADLESS-SVC-NAME -a $REDIS_PASSWORD`.
  * Check if the data has replicated with `get foo`.
  * Be happy, cuz that probably worked.
* Testing Cluster Metrics:
  * Firstly, we have to make the metrics pod accessible from our machine.
  * `kubectl get svc` to get the name of our metrics service and its associated port.
  * Port-forward to the metrics service and port:
    * `kubectl port-forward svc/redis-metrics 9121:9121`
  * Open a new terminal tab, and get the metrics with `curl localhost:9121/metrics`.
* Testing Sentinel Failover:
  * Now let's test the cluster failover handling responsibilites of the Sentinel by simulating a failure of the master node.
  * Spin up another redis client using the same command we used above, the one that started with `kubectl run --namespace...`.
  * Once you are in the new Pod, run `redis-cli -h redis -p 26379 -a $REDIS_PASSWORD` (which is found towards the bottom of output.txt).
  * Run `sentinel masters` to get all the info associated with the current alpha pod.
    * Once we kill the current alpha, we will rerun these commands to confirm the ip listed has changed.
  * Exit Sentinel and the redis-client pod with `exit` x2.
  * Scale down your alpha statefulset:
    * Get the name of your alpha statefulset first with `kubectl get statefulsets`
    * Scale the alpha statefulset down to 0 with `kubectl scale sts STATEFULSET_NAME --replicas=0`
  * Now that you don't have an alpha, Sentinel will begin the process of electing a new one from the available betas. Check the progress by `kubectl logs redis-beta-0 --container=sentinel -f`. 
  * With the above command you can also find which Pod gets selected/voted to be the new alpha. It will be something like: `+switch-master mymaster 111.111.11.000 6379 111.111.1.001 6379` where the first IP is your old alpha, and the second is the new one.
  * Check which of your Pods is now the alpha by cross-referencing the IP in `kubectl get pods -o wide`


## THE FOLLOWING (below) CONFIG FOR REDIS IS DEPRACATED.
### Configuration:
```alpha.conf
bind 0.0.0.0
port 6379

dir /redis-data
```
* `alpha.conf`:
  * The above code directs Redis to bind to all network interfaces on port 6379 and store its files in the /redis-data directory.
```beta.conf
bind 0.0.0.0
port 6379

dir .

slaveof redis-0.redis 6379
```
* `beta.conf`
  * Identical to the alpha, but adds the directive to identify the alpha instance.
  * The name `redis-0.redis` will be setup using a service and a StatefulSet.
* `sentinel.conf` configures the sentinel service with a few options for determining what it should watch, and when it should initiate a failover.
* `init.sh` looks at the hostname for the Pod and determines if its an alpha or beta, depending on which it is, it will launch Redis with the appropriate conf file.
  * Remember to `chmod` this to executable permissions if running locally. The same goes for all other `.sh` scripts.
* `sentinel.sh` is necessary because we need to wait for redis-0.redis DNS name to become available before we start to deploy the sentinel service.  
------------------  
* Once we have created all of the above files and scripts, we need to package them up with a Kubernetes ConfigMap.
```bash
kubectl create configmap \
  --from-file=beta.conf=./beta.conf \
  --from-file=alpha.conf=./alpha.conf \
  --from-file=sentinel.conf=./sentinel.conf \
  --from-file=init.sh=./init.sh \
  --from-file=sentinel.sh=./sentinel.sh \
  redis-config
```
  * In this case we will do this imperatively, but it would also be straightforward to add this command to a script as a part of a CI/CD pipeline.
* `redis-service.yml` is the headless redis service. Apply it before deploying anything using:
  * `kubectl apply -f infra/redis.yml`
* `redis.yml` is the stateful set which creates two containers. One runs the `init.sh` script that we created and the main redis server. The other is the sentinel that monitors the servers.
  * Two volumes are also defined for the Pod. One is the volume that uses our ConfigMap to configure the two Redis Apps. The other is an `emptyDir` volume that is mapped into the Redis server container to hold the app data so it survives a container restart. **FOR A MORE RELIABLE REDIS** use a network attached disk for this instead.
