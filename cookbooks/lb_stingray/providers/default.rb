action :install do

    key = ::File.exists?("/tmp/license.txt") ? "/tmp/license.txt" : ""

    stingray "Stingray Install" do

        accept_license "accept"
        admin_pass node["lb_stingray"]["password"]
        # Use a Gold package for everything except for the unlicensed version.
        gold key == "" ? false : true
        license_key key

        action [:install,:new_cluster]
    end

    if node["cloud"]["provider"] == "ec2" then

        file "#{node["stingray"]["path"]}/zxtm/.EC2" do
            backup false
            action :create
        end

        gs_name = "#{node["stingray"]["path"]}/zxtm/conf/zxtms/#{node["ec2"]["hostname"]}"

        stingray_global_settings gs_name do
            ec2_availability_zone node["ec2"]["placement"]["availability_zone"]
            ec2_instanceid node["ec2"]["instance_id"]
            external_ip "EC2"

            action :configure

        end

        stingray "Stingray Install" do
            action :restart
        end

    end

end

action :add_vhost do

    vsname = "#{node["stingray"]["path"]}/zxtm/conf/vservers/#{new_resource.vhost_name}"
    monitorname = "#{node["stingray"]["path"]}/zxtm/conf/monitors/#{new_resource.vhost_name}"
    persistencename = "#{node["stingray"]["path"]}/zxtm/conf/persistence/#{new_resource.vhost_name}"

    stingray_virtual_server vsname do
        action :configure
    end

    stingray_healthmonitor monitorname do
        action :configure
    end

    stingray_persistence persistencename do
        action :configure
    end

    right_link_tag "loadbalancer:#{new_resource.vhost_name}=lb"

end

action :attach do

    vhost_name = new_resource.vhost_name
    poolname = "#{node["stingray"]["path"]}/zxtm/conf/pools/#{vhost_name}"
    vsname = "#{node["stingray"]["path"]}/zxtm/conf/vservers/#{vhost_name}"
    newnode = "#{new_resource.backend_ip}:#{new_resource.backend_port}"
    pool = Pool.new(poolname)

    stingray_pool poolname do
        nodes pool.nodes.class == Array ? (pool.nodes + [newnode]).uniq : [newnode]
        persistence new_resource.session_sticky ? new_resource.vhost_name : nil
        action :configure
    end

    if pool.nodes == nil then

        stingray_virtual_server vsname do
            pool  vhost_name
            action :configure
        end

    end

end

action :detach do

    vhost_name = new_resource.vhost_name
    poolname = "#{node["stingray"]["path"]}/zxtm/conf/pools/#{vhost_name}"
    vsname = "#{node["stingray"]["path"]}/zxtm/conf/vservers/#{vhost_name}"
    exitnode = "#{new_resource.backend_ip}:#{new_resource.backend_port}"
    pool = Pool.new(poolname)

    log "Existing nodes: #{pool.nodes * " "}. Removing #{exitnode}"

# Possible race condition here.
    pool.nodes.delete(exitnode)

    log "New list of nodes: #{pool.nodes}"

    if pool.nodes.length == 0 then

        stingray_virtual_server vsname do
            pool "discard"
            action :configure
        end

        stingray_pool poolname do
            action :delete
        end

    else

        stingray_pool poolname do
            nodes pool.nodes
            action :configure
        end

    end

end

action :attach_request do

    log " Attach request for #{new_resource.backend_id} /
    #{new_resource.backend_ip} / #{new_resource.vhost_name}"

    remote_recipe "Attach me to load balancer" do
        recipe "lb::handle_attach"
        attributes :remote_recipe => {
            :backend_ip => new_resource.backend_ip,
            :backend_port => new_resource.backend_port,
            :vhost_name => new_resource.vhost_name
        }

        recipients_tags "loadbalancer:#{new_resource.vhost_name}=lb"
    end

end

action :detach_request do
    # Runs on an application server prior to :detach running on the LB device
    vhost_name = new_resource.vhost_name
    log " Detach request for #{new_resource.backend_id} / #{vhost_name}"

    remote_recipe "Detach me from load balancer" do
        recipe "lb::handle_detach"
        attributes :remote_recipe => {
            :backend_ip => new_resource.backend_ip,
            :backend_port => new_resource.backend_port,
            :vhost_names => new_resource.vhost_name
        }
        recipients_tags "loadbalancer:#{vhost_name}=lb"
    end

end

action :restart do

    execute "Restart Stingray" do
        cwd = node["stingray"]["path"]
        command "./restart-zeus"
    end

end

action :setup_monitoring do

end
