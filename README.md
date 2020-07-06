# Redis on K8s!
#### Redis is unique, and deploying it is a unique experience.
Read on for why that is, and to learn how to deploy a simple replicated redis cluster.  
Alternatively, read the Redis documentation, as it certainly does a much better job than I will.  
  
* Outline:
  * Redis is a popular key/value, in-memory store. People use it as a one-stop-shop caching service.
  * Being that Redis deployments are replicated and standalone, it solves some of the traditional problems with server-side caching, namely that clients can connect to any 'server' in the cluster, without us having to worry if it will be the same server that they cached data in previously.
  * **Redis is actually two services running in tandem**:
    * `redis-server`: Which implements the actual key/value store (kvs).
    * `redis-sentinel`: Which, like the name implies, implements health checking and failover on the deployment.
  * **Deploying Redis in a replicated manner means you are deploying a single Alpha server that is used for read/write ops. There are additional Beta servers that duplicate the data on the Alpha, and load balance read operations.**
    * If the Alpha ever fails/goes down, and one of the Betas can fail over to become the new Alpha. This operation is performed by the sentinel.
