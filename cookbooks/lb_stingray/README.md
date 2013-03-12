# Riverbed Stingray Traffic Manager on RightScale Cookbook

# Details

This cookbook provides integration between RightScale's LB interface and
Riverbed Stingray Traffic Manager.  It handles all of the installation and
provides recipes/actions for attaching and detaching application servers
according to the "Infinity" lineage of RightScale's ServerTemplates.

## Description

The load balancer and application server attach/detach recipes are designed so
the servers can locate each other using RightScale machine tags.  The load
balancer servers have tags of the form `loadbalancer:lb=APPLISTENER_NAME` where
`APPLISTENER_NAME` is the name of the application that the application servers
are serving; the application server attach and detach recipes use this machine
tag to request that corresponding handler recipes are run on the matching load
balancers when they need to attach or detach. The application servers have tags
of the form `loadbalancer:app=APPLISTENER_NAME`, `server:uuid=UUID`, and
`loadbalancer:backend_ip=IP_ADDRESS` where `APPLISTENER` is the same application
name, `UUID` is a unique string that identifies the server, and `IP_ADDRESS` is
the IP address of the server; the automatic detection recipe for the load
balancer servers use these tags to find which application servers are currently
available. This mechanism was chosen to support machines in multiple
availability zones where in the case of failures, load balancers and application
servers may start while some machines, including RightScale, are not reachable
and thus the configuration cannot be fully determined. For this reason, the
automatic detection recipe is configured to run every 15 minutes by default.

## Requirements

This particular branch (currently) requires use of the **Infinity** lineage
ServerTemplate by RightScale.  It is not fully compatible with the **LTS**
lineage.

## Setup

By default load balancer has only one pool called **default**, which act as a
default pool for all application servers which has `loadbalancer::app=default`
tag. To setup multiple pools configuration, lb/pools input value must be
overridden with comma-separated list of **URIs** or **FQDNs** for which the load
balancer will create server pools to answer website requests. Last entry will be
the default backend and will answer for all URIs and FQDNs not listed in
lb/pools input. Any combination of URIs or FQDNs or web root relative path can
be entered.  Application servers may provide any numbers of URIs or FQDNs to
join corresponding server pool backends.

## Usage

### Template Inputs

#### lb\_stingray/generic\_binary

This parameter is not meant to be changed by the end user.  It selects a version
of software binary that is compatible with the license key that is being used.
If this value is changed, it's very likely that an instance will fail to
converge.

#### lb\_stingray/version

This parameter is not meant to be changed by the end user.  It selects a version
of the software to install and is only present to avoid cookbook duplication.

#### lb\_stingray/java\_enabled

This is used to specify whether or not Java Extensions should be enabled on the
Traffic Manager.  If you would like to use Java Extensions for Stingray, you
will need to ensure that your ServerTemplate has an appropriate JRE installation
script.  If this is parameter is enabled, and there is no JRE available, the
traffic manager will boot into a state of error (because it won't be able to
find **java**, but will still be functional.

#### lb\_stingray/password

This is used to set the password for the **admin** user when instances are
launched.  It is highly recommended that you set a **credential** using
RightScale's facilities (under **design** --> **credentials**).  Only
text-passwords are supported.  This is the only input parameter that is
required.

### Application Server Attach

#### do\_attach\_request

This recipe is used by application servers to request that load balancer servers
configure themselves to attach to the application server. It requests that
servers with the `loadbalancer:lb=APPLISTENER_NAME` tag run the corresponding
**handle_attach** recipe. The recipe sends the server's IP address, port and
instance `UUID` as parameters to the remote recipe.

#### handle\_attach

This recipe is used by the load balancer servers to reconfigure Stingray when an
application server requests to be attached. It uses the IP address, port and
instance UUID parameters it receives from the **do_attach_request** recipe
called on the application server to construct an individual configuration file
in the `/etc/stingray/lb_stingray.d/services/POOLNAME/servers` directory with
the instance UUID as the file name. If the file didn't exist before or if its
contents change, the main Stingray configuration information is updated by the
**stingray-wrapper.sh** shell script.

### Application Server Detach

#### do\_detach\_request

This recipe is used by application servers to request that load balancer servers
configure themselves to detach from the application server. It request that
servers with the `loadbalancer:lb=APPLISTENER_NAME` tag run the corresponding
**handle_detach** recipe. The recipe sends the server's instance UUID as
parameter to the remote recipe.

#### handle\_detach\_request

This recipe is used by the load balancer servers to reconfigure Stingray when an
application server requests to be detached. It uses the instance UUID parameter
it receives from the **do_detach_request** recipe called on the application
server to delete the corresponding file from the
`/etc/stingray/lb_stingray.d/services/POOLNAME/servers` directory which has the
instance UUID as its file name. If the file was deleted, the main Stingray
configuration information is updated by the **stingray-wrapper.sh** shell
script.

### Automatic Server Detection

#### do\_attach\_all

This recipe is used by the load balancer to automatically detect if application
servers have disappeared or reappeared without detaching or reattaching using
the other recipes. This recipe is set to run in the periodic re-converge which
defaults to a period of 15 minutes between runs. It uses the
`loadbalancer:app=APPLISTENER_NAME`, `server:uuid=UUID`, and
`loadbalancer:backend_ip=IP_ADDRESS` tags to get a list of all of the
application servers that are currently available and uses the list to create,
update, or delete individual server configuration files in the
`/etc/stingray/lb_stingray.d/services/POOLNAME/servers` directory depending on
their current status. If any of the files in the `lb_stingray.d` directory have
been created, changed, or deleted, the main Stingray configuration is updated by
the **stingray-wrapper.sh** shell script.

### Known Limitations

Currently, multiple values in the **lb/pools** input field are not supported,
but this is likely to change very soon.

# License

Copyright Riverbed Technology, Inc. All rights reserved. All access and use
subject to the Riverbed Terms of Service available at www.riverbed.com/license.
