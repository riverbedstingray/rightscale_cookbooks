maintainer       "Riverbed Technology, Inc."
maintainer_email "support@rightscale.com"
license          "Copyright RightScale, Inc. All rights reserved."
description      "Installs/Configures lb_stingray"
long_description IO.read(File.join(File.dirname(__FILE__), 'README.rdoc'))
version          "13.2.0"

# supports "centos", "~> 5.8", "~> 6"
# supports "redhat", "~> 5.8"
# supports "ubuntu", "~> 10.04", "~> 12.04"

depends "rightscale"
depends "app"
depends "lb"

recipe "lb_stingray::default", "This loads the required 'lb' resource using the
Stingray provider."

attribute 'lb_stingray/java_enabled',
:display_name => "Java Extensions",
:description => "Whether or not Java Extensions for TrafficScript should be
enabled.  A JRE must be installed on the host in order for this to function.",
:choice => [ "false", "true" ],
:required => "recommended",
:type => "string",
:recipes => [ "lb_stingray::default" ],
:default => "false"

attribute 'lb_stingray/password',
:display_name => "Stingray Administrative Password",
:description => "The password that you would like to use to access Stingray's
user interface, using the 'admin' user.  This should be a RightScale
credential/password. Example: cred:STINGRAY_ADMIN_PASSWORD",
:required => "required",
:recipes => [ "lb_stingray::default" ]

attribute 'lb_stingray/generic_binary',
:display_name => "Stingray Generic Binary",
:description => "Indicates whether a generic binary, or a RightScale-specifc
binary should be used.  Do not change this value.",
:choice => [ "false", "true" ],
:required => "recommended",
:type => "string",
:recipes => [ "lb_stingray::default" ],
:default => "false"
