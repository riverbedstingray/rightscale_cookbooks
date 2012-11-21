#
# Cookbook Name:: lb_stingray
# Recipe:: default
#
# Copyright 2012, Riverbed Technology
#
# All rights reserved - Do Not Redistribute
#

rightscale_marker :begin

class Chef::Recipe
   include RightScale::App::Helper
end

log "Override load balancer to use Stingray."
node[:lb][:service][:provider] = "lb_stingray"

# 2D array of pools
# Example: [["_serverid", "/serverid"], ["_appsever", "/appsever"], ["default", "default"]]
pool_list = node[:lb][:pools].gsub(/\s+/, "").split(",").uniq.map { |pool| [ pool.gsub(/[\/]/, '_'), pool ] }

pool_list.each do |pool_name_short, pool_name_full|
  log "  Setup default load balancer resource for pool '#{pool_name_short}'."
  log "  load balancer pool full name is '#{pool_name_full}'."

  lb pool_name_short do
    provider "lb_stingray"
    pool_name_full pool_name_full
    persist true # Store this resource in node between converges.
    action :nothing
  end
end

rightscale_marker :end
