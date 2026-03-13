# Certified Stacks

## Go from zero to a fully configured vCluster environment in a single command

<p align="center">
  <img src="assets/certified-stacks.png" alt="Certified Stacks" width="40%" />
</p>

Deploying applications on top of Kubernetes clusters involves stitching together multiple components — operators, controllers, CRDs, Helm charts — and getting the sequencing and configuration right across all of them. Teams spend days or weeks on integration work before anything is production-ready. Certified Stacks eliminate that gap.

A Certified Stack is a tested, versioned, one-command deployment of a vCluster plus a complete application stack. Each stack handles provisioning, dependency orchestration, and configuration automatically, with minimal input required. Define your tenancy model, pick your stack, and go.

### What is vCluster?

[vCluster](https://www.vcluster.com) creates fully functional virtual Kubernetes clusters that run inside namespaces of a host cluster. Each vCluster has its own API server, control plane, and syncer — giving tenants full cluster-level access and isolation without requiring dedicated physical infrastructure. This makes vCluster the foundation for scalable multi-tenancy: platform teams manage one physical cluster while each team, customer, or workload gets its own Kubernetes environment with the flexibility of a real cluster and the efficiency of a shared one.

### Why Certified Stacks

**Multi-tenancy out of the box.** Stacks ship with pre-built configurations for both hard and soft isolation models, so platform teams can match their tenancy architecture to their security and performance requirements without custom integration work.

**Built on validated reference architectures.** Each stack extends partner-published reference architectures with additional deployment flexibility and tenancy options — not a from-scratch reimagining.

**Forkable and extensible.** Every stack is a starting point, not a black box. Fork the repo, modify Helm values, swap components, or adapt the orchestration to your environment. Certified Stacks are designed to be customized — build your own stack for any workload or application.

### Current Certified Stacks

| Stack | Components | Tenancy Models |
|-------|-----------|----------------|
| **NVIDIA Run:ai on vCluster** | vCluster, GPU Operator, NVIDIA Run:ai | Hard isolation, Soft isolation |
| **Slinky on vCluster** | vCluster, GPU Operator, Slinky | Hard isolation, Soft isolation |
| **Ray on vCluster** | vCluster, GPU Operator, Ray | Hard isolation |
| **SkyPilot on vCluster** | vCluster, GPU Operator, SkyPilot | Hard isolation |

More stacks and partner integrations coming soon. Interested in building a Certified Stack for your project or product? [Get in touch →](TODO)
