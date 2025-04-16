provider "aws" {
  region = "us-east-1"
}

# Fetch the default VPC
data "aws_vpc" "default" {
  default = true
}

# Create security group for our instances
resource "aws_security_group" "app_security_group" {
  name        = "app-security-group"
  description = "Security group for servers with Node Exporter and Prometheus"
  vpc_id      = data.aws_vpc.default.id

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Application port access
  ingress {
    from_port   = 4080
    to_port     = 4080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Node Exporter port
  ingress {
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Prometheus port
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana port
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AppSecurityGroup"
  }
}

# EC2 instance for Slave1
resource "aws_instance" "slave1" {
  ami                    = "ami-0c02fb55956c7d316"  # Amazon Linux 2 AMI
  instance_type          = "t2.micro"
  key_name               = "ansible"  # Replace with your key pair
  vpc_security_group_ids = [aws_security_group.app_security_group.id]
  
  tags = {
    Name = "SLAVE1"
  }
}

# EC2 instance for Slave2
resource "aws_instance" "slave2" {
  ami                    = "ami-0c02fb55956c7d316"  # Amazon Linux 2 AMI
  instance_type          = "t2.micro"
  key_name               = "ansible"  # Replace with your key pair
  vpc_security_group_ids = [aws_security_group.app_security_group.id]
  
  tags = {
    Name = "SLAVE2"
  }
}

# EC2 instance for Ansible Server
resource "aws_instance" "ansible_server" {
  ami                    = "ami-0c02fb55956c7d316"  # Amazon Linux 2 AMI
  instance_type          = "t2.micro"
  key_name               = "ansible"
  vpc_security_group_ids = [aws_security_group.app_security_group.id]
  
  depends_on = [aws_instance.slave1, aws_instance.slave2]
  
  # Upload the private key file to Ansible server
  provisioner "file" {
    source      = "ansible.pem"  # Your local key file
    destination = "/home/ec2-user/ansible.pem"
    
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("ansible.pem")
      host        = self.public_ip
    }
  }
  
  # Create the playbook file for Node Exporter deployment
  provisioner "file" {
    content     = <<-EOF
---
- hosts: all
  user: ec2-user
  become: yes
  tasks:
    - name: Install required system packages
      yum:
        name:
          - python3
          - python3-pip
          - git
        state: present
        
    - name: Create installation directory
      file:
        path: /opt/node_exporter
        state: directory
        mode: 0755

    - name: Download node_exporter
      get_url:
        url: "https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz"
        dest: "/tmp/node_exporter-1.9.1.linux-amd64.tar.gz"
        mode: 0644

    - name: Extract node_exporter
      unarchive:
        src: "/tmp/node_exporter-1.9.1.linux-amd64.tar.gz"
        dest: "/opt/node_exporter"
        remote_src: yes
        extra_opts: [--strip-components=1]

    - name: Start node_exporter in background
      shell: "nohup /opt/node_exporter/node_exporter > /opt/node_exporter/node_exporter.log 2>&1 &"
      args:
        creates: "/opt/node_exporter/node_exporter.log"

    - name: Clean up temporary files
      file:
        path: "/tmp/node_exporter-1.9.1.linux-amd64.tar.gz"
        state: absent
    EOF
    destination = "/home/ec2-user/deploy.yml"
    
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("ansible.pem")
      host        = self.public_ip
    }
  }

  # Install and configure Ansible, Node Exporter, Prometheus and Grafana
  provisioner "remote-exec" {
    inline = [
      # Install Ansible
      "sudo su -",
      "sudo amazon-linux-extras install ansible2 -y",
      "sudo yum install -y git",
      "chmod 400 /home/ec2-user/ansible.pem",
      
      # Create inventory file
      "echo '[nodes]' > /home/ec2-user/hosts",
      "echo '${aws_instance.slave1.private_ip} ansible_user=ec2-user ansible_ssh_private_key_file=/home/ec2-user/ansible.pem ansible_ssh_common_args=\"-o StrictHostKeyChecking=no\"' >> /home/ec2-user/hosts",
      "echo '${aws_instance.slave2.private_ip} ansible_user=ec2-user ansible_ssh_private_key_file=/home/ec2-user/ansible.pem ansible_ssh_common_args=\"-o StrictHostKeyChecking=no\"' >> /home/ec2-user/hosts",
      
      # Test connection
      "ansible -i /home/ec2-user/hosts all -m ping",
      
      # Run the playbook to deploy Node Exporter
      "ansible-playbook -i /home/ec2-user/hosts /home/ec2-user/deploy.yml",
      
      # Install Prometheus
      "wget https://github.com/prometheus/prometheus/releases/download/v2.44.0/prometheus-2.44.0.linux-amd64.tar.gz",
      "tar -xvzf prometheus-2.44.0.linux-amd64.tar.gz",
      "wget https://dl.grafana.com/oss/release/grafana-11.6.0.linux-amd64.tar.gz",
      "tar -zxvf grafana-11.6.0.linux-amd64.tar.gz",
      
      "cd prometheus-2.44.0.linux-amd64",
      "sudo cp prometheus promtool /usr/local/bin/",
      
      # Create Prometheus config
      "echo 'global:' > prometheus.yml",
      "echo '  scrape_interval: 15s' >> prometheus.yml",
      "echo '  evaluation_interval: 15s' >> prometheus.yml",
      "echo 'scrape_configs:' >> prometheus.yml",
      "echo '  - job_name: \"prometheus\"' >> prometheus.yml",
      "echo '    static_configs:' >> prometheus.yml",
      "echo '      - targets: [\"localhost:9090\"]' >> prometheus.yml",
      "echo '  - job_name: \"node_exporter\"' >> prometheus.yml",
      "echo '    static_configs:' >> prometheus.yml",
      "echo '      - targets: [\"${aws_instance.slave1.private_ip}:9100\", \"${aws_instance.slave2.private_ip}:9100\"]' >> prometheus.yml",
      
      # Start Prometheus
      "nohup prometheus --config.file=prometheus.yml > prometheus.log 2>&1 &",
      "cd /home/ec2-user/grafana-11.6.0/",
      "nohup ./bin/grafana-server > grafana.log 2>&1 &",
      
      # Install Grafana
      
      
      # Print completion message
      "echo 'Setup complete!'",
      "echo 'Prometheus URL: http://${self.public_ip}:9090'",
      "echo 'Grafana URL: http://${self.public_ip}:3000'"
    ]
    
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("ansible.pem")
      host        = self.public_ip
    }
  }
  
  tags = {
    Name = "AnsibleServer"
  }
}

# Output the public IPs and URLs for easy access
output "slave1_public_ip" {
  value = aws_instance.slave1.public_ip
}

output "slave2_public_ip" {
  value = aws_instance.slave2.public_ip
}

output "ansible_server_public_ip" {
  value = aws_instance.ansible_server.public_ip
}

output "prometheus_url" {
  value = "http://${aws_instance.ansible_server.public_ip}:9090"
}

output "grafana_url" {
  value = "http://${aws_instance.ansible_server.public_ip}:3000"
}