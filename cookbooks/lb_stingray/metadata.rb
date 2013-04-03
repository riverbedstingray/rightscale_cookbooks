maintainer       "Riverbed Technology, Inc."
maintainer_email "mgeldert@riverbed.com"
license          "Copyright Riverbed, Inc. All rights reserved."
description      "Installs/Configures lb_stingray"
long_description IO.read(File.join(File.dirname(__FILE__), 'README.md'))
version          "13.3.0"

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
:choice => [ "no", "yes" ],
:required => "recommended",
:type => "string",
:recipes => [ "lb_stingray::default" ],
:default => "no"

attribute 'lb_stingray/software_version',
:display_name => "Software Version",
:description => "Software version to install (eg. 9.0r1 or 9.1). DO NOT CHANGE THIS VALUE.",
:required => "required",
:type => "string",
:recipes => ["lb_stingray::default"]

attribute 'lb_stingray/binary_hash',
:display_name => "Binary Hash",
:description => "MD5 hash of the software binary to install. DO NOT CHANGE THIS VALUE.",
:required => "required",
:type => "string",
:recipes => ["lb_stingray::default"]

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
binary should be used.  DO NOT CHANGE THIS VALUE.",
:choice => [ "false", "true" ],
:required => "recommended",
:type => "string",
:recipes => [ "lb_stingray::default" ],
:default => "false"
