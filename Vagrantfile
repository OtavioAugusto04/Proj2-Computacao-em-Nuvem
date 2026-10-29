Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "projeto2"
  config.vm.boot_timeout = 600

  config.vm.network "forwarded_port",
    guest: 80,
    host: 8080,
    host_ip: "127.0.0.1"

  config.vm.provider "virtualbox" do |vb|
    vb.cpus = 1
    vb.memory = 4096
    vb.gui = false
  end

  config.vm.provision "shell", path: "provision/provision.sh"
end