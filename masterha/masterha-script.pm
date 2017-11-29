package Extra::MHA;

# kc20130626 to suppport MHA hooks

our $VERSION = '0.1';

1;

package Extra::MHA::Config;

use strict;
use warnings;
use Carp;
use Data::Dumper;

sub new {
  my ( $class, $filename ) = @_;
  bless {
    file    => $filename,
    servers => _load_config($filename),
    },
    __PACKAGE__;
}

sub lookup {
  my ( $self, $ip, $port ) = @_;
  return _lookup( $self->{servers}, $ip, $port );
}

sub is_empty {
  my ($self) = @_;
  return @{ $self->{servers} } == 0;
}

sub _lookup {
  my ( $servers, $ip, $port ) = @_;
  for my $s ( @{$servers} ) {
    if ( $s->{ip} eq $ip && $s->{port} eq $port ) {
      return $s;
    }
  }
}

sub _load_config {
  my ($file) = @_;
  my @lines = ();
  if ( open my $fh, '<', $file ) {
    @lines = <$fh>;
    chomp(@lines);
    close $fh;
  }
  return _parse( \@lines );
}

sub _parse {
  my ($lines) = @_;

  my %global = ();
  my @lookup = ();

  my @block       = ();
  my %setting     = ();
  my $ctx         = "";
  my $i           = 0;
  my %seen_server = ();
  my %seen_vip    = ();
  my %seen_rip    = ();
  for ( @{$lines} ) {
    $i++;
    next if /^\s*(#.*)?$/;    # blank line
    s/#.*$|\s+$//;                 # trim comment or postfix space

    # default setting
    if (/^(\w+)\s+([^#]*)/) {
      $global{$1} = $2;
      $ctx = 'global';
    }

    # servers line
    elsif (/^\d/) {
      if ( $ctx && $ctx eq "setting" ) {    # finish a group
        for (@block) {
          $_ = { %setting, %{$_} };         # ip port won't be overwritten
        }
        push @lookup, @block;
        @block   = ();
        %setting = ();
      }

      $ctx = 'server';
      my @servers = /(\d+\.\d+\.\d+\.\d+:\d+)/g;
      for (@servers) {
        my ( $ip, $port ) = split /:/;
        push @{ $seen_server{"$ip:$port"} }, $i;
        push @{ $seen_rip{$ip} }, $i;
        push @block, { ip => $ip, port => $port };
      }
    }

    # server settings
    elsif (/^\s+\w/) {
      $ctx = 'setting';
      if ( my ( $k, $v ) = /^\s+(\w+)\s+([^#]+)/ ) {
        push( @{ $seen_vip{$v} }, $i ) if $k eq "vip";
        if ( $k eq "proxysql" ) {
          $setting{$k} = _proxysql_parse($v);
        }
        else {
          $setting{$k} = $v;
        }
      }
    }
  }

  # wrap up
  if (@block) {
    for (@block) {
      $_ = { %setting, %{$_} };    # ip port won't be overwritten
    }
    push @lookup, @block;
  }

  for my $server (@lookup) {
    for my $k ( keys %global ) {
      $server->{$k} = $global{$k} unless defined $server->{$k};
    }
  }

  while ( my ( $k, $v ) = each %seen_server ) {
    croak "detected server duplication $k at lines @{$v}" if @{$v} > 1;
  }
  while ( my ( $k, $v ) = each %seen_vip ) {
    croak "detected vip duplication $k at lines @{$v}" if @{$v} > 1;
  }
  for my $vip ( keys %seen_vip ) {
    if ( $seen_rip{$vip} ) {
      croak
"detected vip $vip at line @{$seen_vip{$vip}} duplicates rip at line @{$seen_rip{$vip}}";
    }
  }
  for my $s (@lookup) {
    my $server = "$s->{ip}:$s->{port}";
    croak "vip is not configured for $server at line @{$seen_server{$server}}"
      unless $s->{vip};
    croak
"block_user and block_host must be both or none for $server at line @{$seen_server{$server}}"
      unless ( $s->{block_user} && $s->{block_host} )
      || ( !$s->{block_user} && !$s->{block_host} );
  }

  return \@lookup;
}

sub _proxysql_parse {
  my $list = shift;
  my @proxysql = ();
  my $n = 0;
  # such as: admin:admin@10.0.21.5:6032:r1:w2,admin:admin@10.0.21.7:6032:r1:w2
  foreach (split(/,/, $list)) {
    if (/(\S+?):(\S+?)\@(\S+?):(\d+):w(\d+):r(\d+)/) {
      $proxysql[$n]->{user} = $1;
      $proxysql[$n]->{pass} = $2;
      $proxysql[$n]->{ip}   = $3;
      $proxysql[$n]->{port} = $4;
      $proxysql[$n]->{wgroup} = $5;
      $proxysql[$n]->{rgroup} = $6;
      $n++;
    }
  }
  return \@proxysql;
}

1;

package Extra::MHA::DBHelper;

use base 'MHA::DBHelper';

use strict;
use warnings;
use Carp;

use constant Get_Privileges_SQL => "SHOW GRANTS";
use constant Select_User_Regexp_SQL =>
"SELECT user, host, password FROM mysql.user WHERE user REGEXP ? AND host REGEXP ?";
use constant Set_Password_SQL => "SET PASSWORD FOR ?\@? = ?";

use constant Granted_Privileges =>
  '^GRANT ([A-Z, ]+) ON (`\\w+`|\\*)\\.\\* TO';    # poor match on db
use constant Old_Password_Length          => 16;
use constant Blocked_Empty_Password       => '?' x 41;
use constant Blocked_Old_Password_Head    => '~' x 25;
use constant Blocked_New_Password_Regexp  => qr/^[0-9a-fA-F]{40}\*$/o;
use constant Released_New_Password_Regexp => qr/^\*[0-9a-fA-F]{40}$/o;
use constant Set_Rpl_Semi_Sync_Master_OFF => "SET GLOBAL rpl_semi_sync_master_enabled = OFF";
use constant Set_Rpl_Semi_Sync_Master_ON => "SET GLOBAL rpl_semi_sync_master_enabled = ON";
use constant Set_Rpl_Semi_Sync_Master_Timeout => "SET GLOBAL rpl_semi_sync_master_timeout = 2000";
use constant Set_Rpl_Semi_Sync_Slave_OFF => "SET GLOBAL rpl_semi_sync_slave_enabled = OFF";
use constant Set_Rpl_Semi_Sync_Slave_On => "SET GLOBAL rpl_semi_sync_slave_enabled = ON";

sub new {
  my ($class) = @_;
  bless {}, __PACKAGE__;
}

# see http://code.openark.org/blog/mysql/blocking-user-accounts
sub _blocked_password {
  my $password = shift;
  if ( $password eq '' ) {
    return Blocked_Empty_Password;
  }
  elsif ( length($password) == Old_Password_Length ) {
    return Blocked_Old_Password_Head . $password;
  }
  elsif ( $password =~ Released_New_Password_Regexp ) {
    return join( "", reverse( split //, $password ) );
  }
  else {
    return;
  }
}

sub _released_password {
  my $password = shift;
  if ( $password eq Blocked_Empty_Password ) {
    return '';
  }
  elsif ( index( $password, Blocked_Old_Password_Head ) == 0 ) {
    return substr( $password, length(Blocked_Old_Password_Head) );
  }
  elsif ( $password =~ Blocked_New_Password_Regexp ) {
    return join( "", reverse( split //, $password ) );
  }
  else {
    return;
  }
}

sub _block_release_user_by_regexp {
  my ( $dbh, $user, $host, $block ) = @_;
  my $users_to_block =
    $dbh->selectall_arrayref( Select_User_Regexp_SQL, { Slice => {} },
    $user, $host );
  my $failure = 0;
  for my $u ( @{$users_to_block} ) {
    my $password =
      $block
      ? _blocked_password( $u->{password} )
      : _released_password( $u->{password} );
    if ( defined $password ) {
      my $ret =
        $dbh->do( Set_Password_SQL, undef, $u->{user}, $u->{host}, $password );
      unless ( $ret eq "0E0" ) {
        $failure++;
      }
    }
  }
  return $failure;
}

sub block_user_regexp {
  my ( $self, $user, $host ) = @_;
  return _block_release_user_by_regexp( $self->{dbh}, $user, $host, 1 );
}

sub release_user_regexp {
  my ( $self, $user, $host ) = @_;
  return _block_release_user_by_regexp( $self->{dbh}, $user, $host, 0 );
}

sub rpl_semi_orig_master_set {
  my $self = shift;
  my $status = $self->show_variable("rpl_semi_sync_master_enabled") || '';
  if ($status eq "ON") {
    $self->execute(Set_Rpl_Semi_Sync_Master_OFF);
    $self->execute(Set_Rpl_Semi_Sync_Slave_On);
  }
}

sub rpl_semi_new_master_set {
  my $self = shift;
  my $status = $self->show_variable("rpl_semi_sync_slave_enabled") || '';
  if ($status eq "ON") {
    $self->execute(Set_Rpl_Semi_Sync_Slave_OFF);
    $self->execute(Set_Rpl_Semi_Sync_Master_ON);
    $self->execute(Set_Rpl_Semi_Sync_Master_Timeout);
  }
}

1;

package Extra::MHA::IpHelper;

# helps to manipulate VIP on target host

use strict;
use warnings;
use Carp;

sub new {
  my ( $class, %host_args ) = @_;
  croak "missing host to check against" unless $host_args{host};
  bless \%host_args, __PACKAGE__;
}

# see perlsec
sub _safe_qx {
  my (@cmd) = @_;
  use English '-no_match_vars';
  my $pid;
  croak "Can't fork: $!" unless defined( $pid = open( KID, "-|" ) );
  if ($pid) {    # parent
    if (wantarray) {
      my @output = <KID>;
      close KID;
      return @output;
    }
    else {
      local $/;    # slurp mode
      my $output = <KID>;
      close KID;
      return $output;
    }
  }
  else {
    my @temp     = ( $EUID, $EGID );
    my $orig_uid = $UID;
    my $orig_gid = $GID;
    $EUID = $UID;
    $EGID = $GID;

    # Drop privileges
    $UID = $orig_uid;
    $GID = $orig_gid;

    # Make sure privs are really gone
    ( $EUID, $EGID ) = @temp;
    die "Can’t drop privileges"
      unless $UID == $EUID && $GID eq $EGID;
    $ENV{PATH} = "/bin:/usr/bin";    # Minimal PATH.
         # Consider sanitizing the environment even more.
    exec @cmd
      or die "can’t exec m$cmd[0]: $!";
  }
}

sub ssh_cmd {
  my ( $self, $cmd ) = @_;
  my @cmd = ();
  push @cmd, 'ssh';
  push @cmd, '-l', $self->{user} if $self->{user};
  push @cmd, $self->{host};
  push @cmd, '-p', $self->{port} if $self->{port};
  push @cmd, $cmd;
  return @cmd;
}

sub run_ssh_cmd {
  my ( $self, $cmd ) = @_;
  my @cmd = $self->ssh_cmd($cmd);
  return _safe_qx(@cmd);
}

sub assert_status {
  my ( $high, $low ) = get_run_status();
  if ( $high || $low ) {
    croak "command error $high:$low";
  }
}

sub get_run_status {
  return ( ( $? >> 8 ), ( $? & 0xff ) );    # high, low
}

sub get_ipaddr {
  my ($self) = @_;
  chomp( my @ipaddr = $self->run_ssh_cmd('/sbin/ip addr') );
  assert_status();
  return \@ipaddr;
}

sub parse_ipaddr {
  my $output = shift;
  my %intf   = ();
  my $name;
  for ( @{$output} ) {
    if (/^\d+: (\w+): <[^,]+(?:,[^,]+)*> mtu \d+ qdisc \w+/) {
      $name = $1;
    }
    elsif (/^\s+link\/(\w+) (\S+) brd (\S+)/) {
      $intf{$name}{'link'} = { type => $1, mac => $2, brd => $3 };
    }
    elsif (/^\s+inet ([\d.]+)\/(\d+) (?:brd ([\d.]+))?/) {
      push @{ $intf{$name}{inet} },
        { ip => $1, bits => $2, ( $3 ? ( brd => $3 ) : () ) };
    }
    elsif (/^\w+inet6 ([\d:]+)\/(\d+)/) {
      push @{ $intf{$name}{inet6} }, { ip => $1, bits => $2 };
    }
  }
  return \%intf;
}

sub _get_numeric_ipv4 {
  my @parts = split /\./, shift;
  return ( $parts[0] << 24 ) + ( $parts[1] << 16 ) + ( $parts[2] << 8 ) +
    $parts[3];
}

sub _find_dev {
  my ( $intf, $vip ) = @_;
  for my $dev ( keys %{$intf} ) {
    my $inet = $intf->{$dev}{inet} or next;
    for my $addr ( @{$inet} ) {
      my $m   = ~( ( 1 << ( 32 - $addr->{bits} ) ) - 1 );
      my $ip1 = _get_numeric_ipv4( $addr->{ip} );
      my $ip2 = _get_numeric_ipv4($vip);
      if ( ( $ip1 & $m ) == ( $ip2 & $m ) ) {
        return ( $vip, $addr->{bits}, $dev );
      }
    }
  }
  return;
}

# is vip configured?
sub _check_vip {
  my ( $intf, $vip ) = @_;
  for my $dev ( keys %{$intf} ) {
    my $inet = $intf->{$dev}{inet} or next;
    my $i = 0;
    for my $addr ( @{$inet} ) {
      if ( $addr->{ip} eq $vip ) {
        return ( $vip, $addr->{bits}, $dev )
          if $i > 0;    # 1st entry is RIP rather than VIP
      }
      $i++;
    }
  }
  return;
}

sub find_dev {
  my ( $self, $vip ) = @_;

  my $output = $self->get_ipaddr() or return;
  my $intf = parse_ipaddr($output);

  return _find_dev( $intf, $vip );
}

sub find_dev_with_check {
  my ( $self, $vip ) = @_;

  my $output = $self->get_ipaddr() or return;
  my $intf = parse_ipaddr($output);

  return 1 if _check_vip( $intf, $vip );
  return _find_dev( $intf, $vip );
}

sub check_node_vip {
  my ( $self, $vip ) = @_;

  my $output = $self->get_ipaddr() or return;
  my $intf = parse_ipaddr($output);

  return _check_vip( $intf, $vip );
}

sub stop_vip {
  my ( $self, $vip ) = @_;
  my ( $ip, $bits, $dev ) = $self->check_node_vip($vip)
    or croak "vip $vip is not configured on the node";
  $self->run_ssh_cmd("/sbin/ip addr del $ip/$bits dev $dev");
  assert_status();
  return ( $ip, $bits, $dev );
}

sub start_vip {
  my ( $self, $vip, $dev ) = @_;
  my @vip = $self->find_dev_with_check($vip);
  croak "vip $vip is already configured on the node"
    if @vip == 1;    # some suck trick
  $dev ||= $vip[2];  # third component
  croak "vip $vip does not match any device" unless defined $dev;

  $self->run_ssh_cmd( "/sbin/ip addr add $vip dev $dev"
      . ( $dev =~ /^lo/ ? "" : "; /sbin/arping -U -I $dev -c 3 $vip" ) );
  assert_status();
}

1;


package Extra::MHA::Proxysql;

use strict;
use warnings;
use Carp;

use constant Proxysql_Read_Only => "PROXYSQL READONLY";
use constant Proxysql_Read_Write => "PROXYSQL READWRITE";
use constant Proxysql_Load_Variable_To_Runtime => "LOAD MYSQL VARIABLES TO RUNTIME";
use constant Proxysql_Load_Servers_To_Runtime => "LOAD MYSQL SERVERS TO RUNTIME";
use constant Proxysql_Save_Variable_To_Disk => "SAVE MYSQL SERVERS TO DISK";

use constant Proxysql_Delete_Repl_Group => 
  "DELETE FROM mysql_replication_hostgroups WHERE writer_hostgroup = ? AND reader_hostgroup = ?";
use constant Proxysql_Insert_Repl_Group => 
  "REPLACE INTO mysql_replication_hostgroups (writer_hostgroup, reader_hostgroup, comment) "
  . "VALUES (?, ?, ?)";
use constant Proxysql_Delete_Hostgroup => 
  "DELETE FROM mysql_servers WHERE hostgroup_id in (?, ?) AND hostname = ? AND port = ?";
use constant Proxysql_Insert_New_Server => 
  "REPLACE INTO mysql_servers " . 
  "(hostgroup_id, hostname, port, status, weight, max_connections, max_replication_lag) " .
  "VALUES (?, ?, ?, ?, ?, ?, ?)";

sub new {
  my ($class) = @_;
  bless {}, __PACKAGE__;
}

sub connect {
  my $self = shift;
  my $host = shift;
  my $port = shift;
  my $user = shift;
  my $password = shift;
  my $database = shift;
  my $raise_error = shift;
  $raise_error = 0 if ( !defined($raise_error) );
  my $defaults = { 
    PrintError => 0,
    RaiseError => ( $raise_error ? 1 : 0 ),
  };

  $database ||= "";
  my $dbh = eval {
    DBI->connect("DBI:mysql:database=$database;host=$host;port=$port",
      $user, $password, $defaults);
  };  
  if (!$dbh && $@) {
    carp "get proxysql connect for $host:$port error:$@";
    return undef;
  }
  $self->{dbh} = $dbh;
}

sub disconnect {
  my $self = shift;
  $self->{dbh}->disconnect();
}


sub proxysql_readonly {
  my $self = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Read_Only);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  return $failure;
}

sub proxysql_readwrite {
  my $self = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Read_Write);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  return $failure;
}

sub proxysql_delete_repl_group {
  my $self = shift;
  my $wgroup = shift;
  my $rgroup = shift;
  my $failure = 0;
  if ($wgroup && $rgroup) {
    eval {
      $self->{dbh}->do(Proxysql_Delete_Repl_Group, undef, $wgroup, $rgroup);
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++;
  }
  return $failure;
}

sub proxysql_insert_repl_group {
  my $self = shift;
  my $wgroup = shift;
  my $rgroup = shift;
  my $failure = 0;
  if ($wgroup && $rgroup) {
    eval {
      $self->{dbh}->do(Proxysql_Insert_Repl_Group, 
         undef, $wgroup, $rgroup, "MHA switch proxysql");
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++
  }
  return $failure;
}

sub proxysql_delete_group {
  my ($self, $wgroup, $rgroup, $host, $port) = @_;
  my $failure = 0;
  if ($wgroup && $rgroup && $host && $port) {
    eval {
      $self->{dbh}->do(Proxysql_Delete_Hostgroup, undef, $wgroup, $rgroup, $host, $port);
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++;
  }
  return $failure;
}

sub proxysql_insert_new_server {
  my ($self, $group, $host, $port, $lag) = @_;
  my $failure = 0;
  if ($group && $host && $port) {
    eval{
      $self->{dbh}->do(Proxysql_Insert_New_Server, undef, $group, $host, $port, 
            'ONLINE', 1000, 2000, $lag);
    };
    if ($@) {
      $failure++;
    }
  }
  else {
    $failure++;
  }
  return $failure;
}

sub proxysql_load_server_to_runtime {
  my $self = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Load_Servers_To_Runtime);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  return $failure;
}

sub proxysql_save_server_to_disk {
  my $self = shift;
  my $dbh = shift;
  my $failure = 0;
  my $ret = $self->{dbh}->do(Proxysql_Save_Variable_To_Disk);
  unless ($ret eq "0E0") {
    $failure++;
  }
  else {
    $self->{dbh}->do(Proxysql_Load_Variable_To_Runtime);
  }
  return $failure;
}

1;
