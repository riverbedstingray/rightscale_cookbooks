# 
# Cookbook Name:: lb_haproxy
#
# Copyright RightScale, Inc. All rights reserved.  All access and use subject to the
# RightScale Terms of Service available at http://www.rightscale.com/terms.php and,
# if applicable, other agreements such as a RightScale Master Subscription Agreement.

action :install do

  log "  Installing haproxy"

  # Install haproxy package.
  package "haproxy" do
    action :install
  end

  # Create haproxy service.
  service "haproxy" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :enable
  end

  # Install haproxy file depending on OS/platform.
  template "/etc/default/haproxy" do
    only_if { node[:platform] == "debian" || node[:platform] == "ubuntu" }
    source "default_haproxy.erb"
    cookbook "lb_haproxy"
    owner "root"
    notifies :restart, resources(:service => "haproxy")
  end

  # Create /home/lb directory.
  directory "/home/lb/#{node[:lb][:service][:provider]}.d" do
    owner "haproxy"
    group "haproxy"
    mode 0755
    recursive true
    action :create
  end

  # Install script that concatenates individual server files after the haproxy config head into the haproxy config.
  cookbook_file "/home/lb/haproxy-cat.sh" do
    owner "haproxy"
    group "haproxy"
    mode 0755
    source "haproxy-cat.sh"
    cookbook "lb_haproxy"
  end

  # Install the haproxy config head which is the part of the haproxy config that doesn't change.
  template "/home/lb/rightscale_lb.cfg.head" do
    source "haproxy_http.erb"
    cookbook "lb_haproxy"
    owner "haproxy"
    group "haproxy"
    mode "0400"
    stats_file="stats socket /home/lb/status user haproxy group haproxy"
    variables(
      :stats_file_line => stats_file
    )
  end
  pool_name = new_resource.pool_name
  # Install the haproxy config backend which is the part of the haproxy config that doesn't change.
  template "/home/lb/rightscale_lb.cfg.default_backend" do
    source "haproxy_default_backend.erb"
    cookbook "lb_haproxy"
    owner "haproxy"
    group "haproxy"
    mode "0400"
    #default_backend = node[:lb][:pool_names].gsub(/\s+/, "").split(",").first.gsub(/\./, "_") + "_backend"
    variables(
      #:default_backend_line => default_backend
       :default_backend_line => "#{pool_name}_backend"
    )
  end

  # Generate the haproxy config file.
  execute "/home/lb/haproxy-cat.sh" do
    user "haproxy"
    group "haproxy"
    umask 0077
    notifies :start, resources(:service => "haproxy")
  end

  # Remove haproxy config file so we can symlink it.
  file "/etc/haproxy/haproxy.cfg" do
    backup false
    not_if { ::File.symlink?("/etc/haproxy/haproxy.cfg") }
    action :delete
  end

  # Symlink haproxy config.
  link "/etc/haproxy/haproxy.cfg" do
    to "/home/lb/rightscale_lb.cfg"
  end

end


action :add_vhost do

  pool_name = new_resource.pool_name

  # Create the directory for vhost server files.
  directory "/home/lb/#{node[:lb][:service][:provider]}.d/#{pool_name}" do
    owner "haproxy"
    group "haproxy"
    mode 0755
    recursive true
    action :create
  end
=begin
  # Create backend haproxy files for vhost it will answer for.
  template ::File.join("/home/lb/#{node[:lb][:service][:provider]}.d", "#{pool_name}.cfg") do
    source "haproxy_backend.erb"
    cookbook 'lb_haproxy'
    owner "haproxy"
    group "haproxy"
    mode "0400"
    backend_name = pool_name.gsub(".", "_") + "_backend"
    stats_uri = "stats uri #{node[:lb][:stats_uri]}" unless "#{node[:lb][:stats_uri]}".empty?
    stats_auth = "stats auth #{node[:lb][:stats_user]}:#{node[:lb][:stats_password]}" unless \
                "#{node[:lb][:stats_user]}".empty? || "#{node[:lb][:stats_password]}".empty?
    health_uri = "option httpchk GET #{node[:lb][:health_check_uri]}" unless "#{node[:lb][:health_check_uri]}".empty?
    health_chk = "http-check disable-on-404" unless "#{node[:lb][:health_check_uri]}".empty?
    variables(
      :userlist_pool_name => "",
      :backend_name_line => backend_name,
      :stats_uri_line => stats_uri,
      :stats_auth_line => stats_auth,
      :health_uri_line => health_uri,
      :health_check_line => health_chk
    )
  end
=end
  lb_haproxy_backend  "create main backend section" do
    pool_name  pool_name
    advanced_configs "false"
  end

  action_advanced_configs



  # (Re)generate the haproxy config file.
  execute "/home/lb/haproxy-cat.sh" do
    user "haproxy"
    group "haproxy"
    umask 0077
    action :run
    notifies :reload, resources(:service => "haproxy")
  end

  # Tag this server as a load balancer for vhost it will answer for so app servers can send requests to it.
  right_link_tag "loadbalancer:#{pool_name}=lb"

end


action :attach do

  pool_name = new_resource.pool_name

  log "  Attaching #{new_resource.backend_id} / #{new_resource.backend_ip} / #{pool_name}"

  # Create haproxy service.
  service "haproxy" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :nothing
  end

  # (Re)generate the haproxy config file.
  execute "/home/lb/haproxy-cat.sh" do
    user "haproxy"
    group "haproxy"
    umask 0077
    action :nothing
    persist true
    notifies :reload, resources(:service => "haproxy")
  end

  # Create an individual server file for each vhost and notify the concatenation script if necessary.
  template ::File.join("/home/lb/#{node[:lb][:service][:provider]}.d", pool_name, new_resource.backend_id) do
    source "haproxy_server.erb"
    owner "haproxy"
    group "haproxy"
    mode 0600
    backup false
    cookbook "lb_haproxy"
    variables(
      :backend_name => new_resource.backend_id,
      :backend_ip => new_resource.backend_ip,
      :backend_port => new_resource.backend_port,
      :max_conn_per_server => node[:lb][:max_conn_per_server],
      :session_sticky => new_resource.session_sticky,
      :health_check_uri => node[:lb][:health_check_uri]
    )
    notifies :run, resources(:execute => "/home/lb/haproxy-cat.sh")
  end


  action_advanced_configs



end

action :advanced_configs do

  #TO-DO: remove this
  service "haproxy" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :nothing
  end

  execute "/home/lb/haproxy-cat.sh" do
    user "haproxy"
    group "haproxy"
    umask 0077
    action :nothing
    notifies :reload, resources(:service => "haproxy")
  end


  pool_name = new_resource.pool_name
  pool_name_full =  new_resource.pool_name_full
  backend_authorized_users = new_resource.backend_authorized_users
  log "  Current pool name is #{pool_name}"
  log "  Current  FULL pool name is #{pool_name_full}"
  # if pool_name include "/" we assume that we have URI in tag so we will
  # generate new acls and conditions

  #acl_config_file = "/home/lb/#{node[:lb][:service][:provider]}.d/acl_#{pool_name}.conf"
  #file acl_config_file

  #use_backend_config_file = "/home/lb/#{node[:lb][:service][:provider]}.d/use_backend_#{pool_name}.conf"
  #file use_backend_config_file

  #userlist_backend_config_file = "/home/lb/#{node[:lb][:service][:provider]}.d/userlist_backend_#{pool_name}.conf"
  #file userlist_backend_config_file


  #backend_config_file = "/home/lb/#{node[:lb][:service][:provider]}.d/#{pool_name}.cfg"
=begin
  if pool_name_full.include? "/"
    # RESULT EXAMPLE
    # acl url_serverid  path_beg    /serverid
    acl_rule = "acl acl_#{pool_name} path_beg #{pool_name_full}"
  else
    # we assume that user enter FQDN
    # RESULT EXAMPLE
    # acl ns-ss-db1-test-rightscale-com_acl  hdr_dom(host) -i ns-ss-db1.test.rightscale.com
    acl_rule = "acl acl_#{new_resource.pool_name} hdr_dom(host) -i #{new_resource.pool_name}"
  end

  bash "Creating acl rules config file" do
    flags "-ex"
    code <<-EOH
       echo "        #{acl_rule}" >> #{acl_config_file}
    EOH
    not_if do ::File.open(acl_config_file, 'r') { |f| f.read }.include? "#{acl_rule}" end
  end
=end

  template "/home/lb/#{node[:lb][:service][:provider]}.d/acl_#{pool_name}.conf" do
     source "haproxy_backend_acl.erb"
     owner "haproxy"
     group "haproxy"
     mode 0600
     backup false
     cookbook "lb_haproxy"
     variables(
       :pool_name => pool_name,
       :pool_name_full => pool_name_full
     )
  end

  #######################################################################
=begin
  # RESULT EXAMPLE
  # use_backend 2_backend if url_serverid
  use_backend_rule = "use_backend #{pool_name}_backend if acl_#{pool_name}"
  bash "Creating use_backend rule configs" do
    flags "-ex"
    code <<-EOH
      echo "        #{use_backend_rule}" >> #{use_backend_config_file}
    EOH
    not_if do ::File.open(use_backend_config_file, 'r') { |f| f.read }.include? "#{use_backend_rule}" end
  end
=end

  template "/home/lb/#{node[:lb][:service][:provider]}.d/use_backend_#{pool_name}.conf" do
    source "haproxy_backend_use.erb"
    owner "haproxy"
    group "haproxy"
    mode 0600
    backup false
    cookbook "lb_haproxy"
    variables(
      :pool_name => pool_name,
      :pool_name_full => pool_name_full
    )
  end

  if backend_authorized_users
=begin
          userlist UsersFor__appserver
          user user1 insecure-password 678

          backend _appserver_backend
             acl Auth__appserver http_auth(UsersFor__appserver)
             http-request auth realm _appserver if !Auth__appserver
=end
    log "!!! Current cred is : #{backend_authorized_users}"

=begin
    user_list = "userlist UsersFor_#{pool_name}"

    bash "Add authorization rules section" do
      flags "-ex"
      code <<-EOH
        echo "\n    #{user_list}\n" >> #{userlist_backend_config_file}
      EOH
      #not_if do ::File.open(userlist_backend_config_file, 'r') { |f| f.read }.include? "#{realm}" end
    end


    backend_authorized_users.each do |user_and_pass|
      user_pair = user_and_pass.split ":"
      user_string = "user #{user_pair[0]} insecure-password #{user_pair[1]}"

      bash "Add user string" do
        flags "-ex"
        code <<-EOH
          echo "\n    #{user_string}\n" >> #{userlist_backend_config_file}
        EOH
        not_if do ::File.open(userlist_backend_config_file, 'r') { |f| f.read }.include? "#{user_string}" end
      end

    end
=end

    template "/home/lb/#{node[:lb][:service][:provider]}.d/userlist_backend_#{pool_name}.conf" do
         source "haproxy_backend_userlist.erb"
         owner "haproxy"
         group "haproxy"
         mode 0600
         backup false
         cookbook "lb_haproxy"
         variables(
           :pool_name => pool_name,
           :user_credentials => backend_authorized_users
         )
    end

=begin
    http_auth_acl = "acl Auth_#{pool_name} http_auth(UsersFor_#{pool_name})"
    realm = "http-request auth realm Please_enter_your_credentials if !Auth_#{pool_name}"

    bash "Add backend authorization rules to #{pool_name}.cfg" do
      flags "-ex"
      code <<-EOH
        echo "\n         #{http_auth_acl}\n         #{realm}\n" >> #{backend_config_file}
      EOH
      not_if do ::File.open(backend_config_file, 'r') { |f| f.read }.include? "#{realm}" end
    end

      # Recreate an individual server file for each vhost and notify the concatenation script if necessary.
  template "/home/lb/#{node[:lb][:service][:provider]}.d/#{pool_name}.cfg" do
    source "haproxy_backend.erb"
    owner "haproxy"
    group "haproxy"
    mode 0600
    backup false
    cookbook "lb_haproxy"
    variables(
      :pool_name => new_resource.pool_name,
      :backend_name => new_resource.backend_id,
      :backend_ip => new_resource.backend_ip,
      :backend_port => new_resource.backend_port,
      :max_conn_per_server => node[:lb][:max_conn_per_server],
      :session_sticky => new_resource.session_sticky,
      :health_check_uri => node[:lb][:health_check_uri]
    )
    notifies :run, resources(:execute => "/home/lb/haproxy-cat.sh")
  end
=end

  lb_haproxy_backend  "create main backend section" do
    pool_name  pool_name
    advanced_configs "true"
    notifies :run, resources(:execute => "/home/lb/haproxy-cat.sh")
  end

    execute "/home/lb/haproxy-cat.sh" do
    user "haproxy"
    group "haproxy"
    umask 0077
    action :run
    notifies :reload, resources(:service => "haproxy")
  end

  end

end


action :attach_request do

  pool_name = new_resource.pool_name

  log "  Attach request for #{new_resource.backend_id} / #{new_resource.backend_ip} / #{pool_name}"

  # Run remote_recipe for each vhost app server wants to be part of.
  remote_recipe "Attach me to load balancer" do
    recipe "lb::handle_attach"
    attributes :remote_recipe => {
      :backend_ip => new_resource.backend_ip,
      :backend_id => new_resource.backend_id,
      :backend_port => new_resource.backend_port,
      :pool_names => pool_name
    }
    recipients_tags "loadbalancer:#{pool_name}=lb"
  end

end


action :detach do

  pool_name = new_resource.pool_name

  log "  Detaching #{new_resource.backend_id} from #{pool_name}"

  # Create haproxy service.
  service "haproxy" do
    supports :reload => true, :restart => true, :status => true, :start => true, :stop => true
    action :nothing
  end

  # (Re)generate the haproxy config file.
  execute "/home/lb/haproxy-cat.sh" do
    user "haproxy"
    group "haproxy"
    umask 0077
    action :nothing
    notifies :reload, resources(:service => "haproxy")
  end

  # Delete the individual server file and notify the concatenation script if necessary.
  file ::File.join("/home/lb/#{node[:lb][:service][:provider]}.d", pool_name, new_resource.backend_id) do
    action :delete
    backup false
    notifies :run, resources(:execute => "/home/lb/haproxy-cat.sh")
  end

end


action :detach_request do

  pool_name = new_resource.pool_name

  log "  Detach request for #{new_resource.backend_id} / #{pool_name}"

  # Run remote_recipe for each vhost app server is part of.
  remote_recipe "Detach me from load balancer" do
    recipe "lb::handle_detach"
    attributes :remote_recipe => {
      :backend_id => new_resource.backend_id,
      :pool_names => pool_name
    }
    recipients_tags "loadbalancer:#{pool_name}=lb"
  end

end


action :setup_monitoring do

  log "  Setup monitoring for haproxy"

  # Install the haproxy collectd script into the collectd library plugins directory.
  cookbook_file(::File.join(node[:rightscale][:collectd_lib], "plugins", "haproxy")) do
    source "haproxy1.4.rb"
    cookbook "lb_haproxy"
    mode "0755"
  end

  # Add a collectd config file for the haproxy collectd script with the exec plugin and restart collectd if necessary.
  template ::File.join(node[:rightscale][:collectd_plugin_dir], "haproxy.conf") do
    backup false
    source "haproxy_collectd_exec.erb"
    notifies :restart, resources(:service => "collectd")
    cookbook "lb_haproxy"
  end

  ruby_block "add_collectd_gauges" do
    block do
      types_file = ::File.join(node[:rightscale][:collectd_share], "types.db")
      typesdb = IO.read(types_file)
      unless typesdb.include?("gague-age") && typesdb.include?("haproxy_sessions")
        typesdb += <<-EOS
          haproxy_sessions current_queued:GAUGE:0:65535, current_session:GAUGE:0:65535
          haproxy_traffic cumulative_requests:COUNTER:0:200000000, response_errors:COUNTER:0:200000000, health_check_errors:COUNTER:0:200000000
          haproxy_status status:GAUGE:-255:255
        EOS
        ::File.open(types_file, "w") { |f| f.write(typesdb) }
      end
    end
  end

end


action :restart do

  log "  Restarting haproxy"

  require 'timeout'

  Timeout::timeout(new_resource.timeout) do
    while true
      `service #{new_resource.name} stop`
      break if `service #{new_resource.name} status` !~ /is running/
      Chef::Log.info "service #{new_resource.name} not stopped; retrying in 5 seconds"
      sleep 5
    end

    while true
      `service #{new_resource.name} start`
      break if `service #{new_resource.name} status` =~ /is running/
      Chef::Log.info "service #{new_resource.name} not started; retrying in 5 seconds"
      sleep 5
    end
  end

end
