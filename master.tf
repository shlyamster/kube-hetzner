resource "hcloud_server" "first_control_plane" {
  name = "k3s-control-plane-0"

  image              = data.hcloud_image.linux.name
  rescue             = "linux64"
  server_type        = var.control_plane_server_type
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.k3s.id]
  firewall_ids       = [hcloud_firewall.k3s.id]
  placement_group_id = hcloud_placement_group.k3s.id

  labels = {
    "provisioner" = "terraform",
    "engine"      = "k3s"
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

  # Generating k3s master config file
  provisioner "file" {
    content = yamlencode({
      node-name                = self.name
      cluster-init             = true
      disable-cloud-controller = true
      disable                  = ["servicelb", "local-storage"]
      flannel-iface            = "eth1"
      kubelet-arg              = "cloud-provider=external"
      node-ip                  = local.first_control_plane_network_ip
      advertise-address        = local.first_control_plane_network_ip
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

  # Run the first control plane
  provisioner "remote-exec" {
    inline = [
      # set the hostname in a persistent fashion
      "hostnamectl set-hostname ${self.name}",
      # first we disable automatic reboot (after transactional updates), and configure the reboot method as kured
      "rebootmgrctl set-strategy off && echo 'REBOOT_METHOD=kured' > /etc/transactional-update.conf",
      # then we initiate the cluster
      "systemctl enable k3s-server",
      <<-EOT
        until systemctl status k3s-server > /dev/null
        do
          systemctl start k3s-server
          echo "Initiating the cluster..."
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

  # Get the Kubeconfig, and wait for the node to be available
  provisioner "local-exec" {
    command = <<-EOT
      until ssh -q ${local.ssh_args} root@${self.ipv4_address} [[ -f /etc/rancher/k3s/k3s.yaml ]]
      do
        echo "Waiting for the k3s config file to be ready..."
        sleep 2
      done
      scp ${local.ssh_args} root@${self.ipv4_address}:/etc/rancher/k3s/k3s.yaml ${path.module}/kubeconfig.yaml
      sed -i -e 's/127.0.0.1/${self.ipv4_address}/g' ${path.module}/kubeconfig.yaml
      until kubectl get node ${self.name} --kubeconfig ${path.module}/kubeconfig.yaml 2> /dev/null || false
      do 
        echo "Waiting for the node to become available...";
        sleep 2
      done
    EOT
  }

  # Install the Hetzner CCM and CSI
  provisioner "local-exec" {
    command = <<-EOT
      set -ex
      kubectl -n kube-system create secret generic hcloud --from-literal=token=${var.hcloud_token} --from-literal=network=${hcloud_network.k3s.name} --kubeconfig ${path.module}/kubeconfig.yaml
      kubectl apply -k ${dirname(local_file.hetzner_ccm_config.filename)} --kubeconfig ${path.module}/kubeconfig.yaml
      kubectl -n kube-system create secret generic hcloud-csi --from-literal=token=${var.hcloud_token} --kubeconfig ${path.module}/kubeconfig.yaml
      kubectl apply -k ${dirname(local_file.hetzner_csi_config.filename)} --kubeconfig ${path.module}/kubeconfig.yaml
    EOT
  }

  # Install Kured
  provisioner "local-exec" {
    command = <<-EOT
      set -ex
      kubectl -n kube-system apply -k ${dirname(local_file.kured_config.filename)} --kubeconfig ${path.module}/kubeconfig.yaml
    EOT
  }

  # Configure the Traefik ingress controller
  provisioner "local-exec" {
    command = <<-EOT
      set -ex
      kubectl apply -f ${local_file.traefik_config.filename} --kubeconfig ${path.module}/kubeconfig.yaml
    EOT
  }

  network {
    network_id = hcloud_network.k3s.id
    ip         = local.first_control_plane_network_ip
  }

  depends_on = [
    hcloud_network_subnet.k3s,
    hcloud_firewall.k3s
  ]
}
