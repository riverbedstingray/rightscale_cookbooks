#
# Cookbook Name:: lb_stingray
# Recipe:: default
#
# Copyright 2012, YOUR_COMPANY_NAME
#
# All rights reserved - Do Not Redistribute
#

rightscale_marker :begin

class Chef::Recipe
   include RightScale::App::Helper
end

log "   Override load balancer to use Stingray."
node[:lb][:service][:provider] = "lb_stingray"

vhosts(node[:lb][:vhost_names]).each do | vhost_name |
   log "    Setup default load balancer resource for vhost '#{vhost_name}'."
   lb vhost_name do
      provider node[:lb][:service][:provider] = "lb_stingray"
      persist true
      action :nothing
   end
end

rightscale_marker :end
