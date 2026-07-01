output "node_ips" {
  description = "IP addresses assigned to each node"
  value = {
    for name, node in var.nodes : name => node.ip
  }
}
