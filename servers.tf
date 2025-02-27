resource "hcloud_server" "control_planes" {
  count = var.servers_num - 1
  name  = "k3s-control-plane-${count.index + 1}"

  image              = data.hcloud_image.linux.name
  rescue             = "linux64"
  server_type        = var.control_plane_server_type
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.k3s.id]
  firewall_ids       = [hcloud_firewall.k3s.id]
  placement_group_id = hcloud_placement_group.k3s.id

  labels = {
    "provisioner" = "terraform",
    "engine"      = "k3s",
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/config.ign.tpl", {
      name           = self.name
      ssh_public_key = local.ssh_public_key
    })
    destination = "/root/config.ign"

    connection {
      user           = "root"
      private_key    = local.ssh_private_key
      agent_identity = local.ssh_identity
      host           = self.ipv4_address
    }
  }

  # Install MicroOS
  provisioner "remote-exec" {
    inline = local.MicroOS_install_commands

    connection {
      user           = "root"
      private_key    = local.ssh_private_key
      agent_identity = local.ssh_identity
      host           = self.ipv4_address
    }
  }

  # Issue a reboot command
  provisioner "local-exec" {
    command = "ssh ${local.ssh_args} root@${self.ipv4_address} '(sleep 2; reboot)&'; sleep 3"
  }

  # Wait for MicroOS to reboot and be ready
  provisioner "local-exec" {
    command = <<-EOT
      until ssh ${local.ssh_args} -o ConnectTimeout=2 root@${self.ipv4_address} true 2> /dev/null
      do
        echo "Waiting for MicroOS to reboot and become available..."
        sleep 2
      done
    EOT
  }

  # Generating k3s server config file
  provisioner "file" {
    content = yamlencode({
      node-name                = self.name
      server                   = "https://${local.first_control_plane_network_ip}:6443"
      cluster-init             = true
      disable-cloud-controller = true
      disable                  = "servicelb, local-storage"
      flannel-iface            = "eth1"
      kubelet-arg              = "cloud-provider=external"
      node-ip                  = cidrhost(hcloud_network_subnet.k3s.ip_range, 3 + count.index)
      advertise-address        = cidrhost(hcloud_network_subnet.k3s.ip_range, 3 + count.index)
      tls-san                  = cidrhost(hcloud_network_subnet.k3s.ip_range, 3 + count.index)
      token                    = random_password.k3s_token.result
      node-taint               = var.allow_scheduling_on_control_plane ? [] : ["node-role.kubernetes.io/master:NoSchedule"]
    })
    destination = "/etc/rancher/k3s/config.yaml"

    connection {
      user           = "root"
      private_key    = local.ssh_private_key
      agent_identity = local.ssh_identity
      host           = self.ipv4_address
    }
  }

  # Run an other control plane server
  provisioner "remote-exec" {
    inline = [
      # set the hostname in a persistent fashion
      "hostnamectl set-hostname ${self.name}",
      # first we disable automatic reboot (after transactional updates), and configure the reboot method as kured
      "rebootmgrctl set-strategy off && echo 'REBOOT_METHOD=kured' > /etc/transactional-update.conf",
      # then then we start k3s in server mode and join the cluster
      "systemctl enable k3s-server",
      <<-EOT
        until systemctl status k3s-server > /dev/null
        do
          systemctl start k3s-server
          echo "Waiting on other 'learning' control planes, patience is the mother of all virtues..."
          sleep 2
        done
      EOT
    ]

    connection {
      user           = "root"
      private_key    = local.ssh_private_key
      agent_identity = local.ssh_identity
      host           = self.ipv4_address
    }
  }

  network {
    network_id = hcloud_network.k3s.id
    ip         = cidrhost(hcloud_network_subnet.k3s.ip_range, 3 + count.index)
  }

  depends_on = [
    hcloud_server.first_control_plane,
    hcloud_network_subnet.k3s
  ]
}
