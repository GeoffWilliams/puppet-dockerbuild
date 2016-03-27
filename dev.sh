docker run -d --privileged \
  --name dockerbuild-dev \
  --volume /sys/fs/cgroup:/sys/fs/cgroup \
  --volume /etc/puppetlabs \
  --volume /var/log \
  --volume /opt/puppetlabs/server/data \
  --volume $(pwd):/scratch \
  --hostname pe-puppet.localdomain\
  --restart always \
  -p 9000 \
geoffwilliams/pe_master_public_lowmem_r10k_dockerbuild:2015.3.3-6
