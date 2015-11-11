package PVE::Storage::LvmThinPlugin;

use strict;
use warnings;
use Data::Dumper;
use IO::File;
use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::Storage::LVMPlugin;
use PVE::JSONSchema qw(get_standard_option);

# see: man lvmthin
# lvcreate -n ThinDataLV -L LargeSize VG
# lvconvert --type thin-pool VG/ThinDataLV
# lvcreate -n pvepool -L 20G pve
# lvconvert --type thin-pool pve/pvepool

use base qw(PVE::Storage::LVMPlugin);

sub type {
    return 'lvmthin';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1}, { images => 1, rootdir => 1}],
    };
}

sub properties {
    return {
	thinpool => {
	    description => "LVM thin pool LV name.",
	    type => 'string', format => 'pve-storage-vgname',
	},
    };
}

sub options {
    return {
	thinpool => { fixed => 1 },
	vgname => { fixed => 1 },
        nodes => { optional => 1 },
	disable => { optional => 1 },
	content => { optional => 1 },
    };
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - sould be 'vm-$vmid-*'\n"
	if  $name && $name !~ m/^vm-$vmid-/;

    my $vg = $scfg->{vgname};

    if (!$name) {
	my $lvs = PVE::Storage::LVMPlugin::lvm_list_volumes($scfg->{vgname});

	for (my $i = 1; $i < 100; $i++) {
	    my $tn = "vm-$vmid-disk-$i";
	    if (!defined ($lvs->{$vg}->{$tn})) {
		$name = $tn;
		last;
	    }
	}
    }

    my $cmd = ['/sbin/lvcreate', '-aly', '-V', "${size}k", '--name', $name,
	       '--thinpool', "$vg/$scfg->{thinpool}" ];

    run_command($cmd, errmsg => "lvcreate '$vg/$name' error");

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $vg = $scfg->{vgname};
    my $cmd = ['/sbin/lvremove', '-f', "$vg/$volname"];
    run_command($cmd, errmsg => "lvremove '$vg/$volname' error");

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $vgname = $scfg->{vgname};

    $cache->{lvs} = PVE::Storage::LVMPlugin::lvm_list_volumes() if !$cache->{lvs};

    my $res = [];

    if (my $dat = $cache->{lvs}->{$vgname}) {

	foreach my $volname (keys %$dat) {

	    next if $volname !~ m/^vm-(\d+)-/;
	    my $owner = $1;

	    my $info = $dat->{$volname};

	    next if $info->{lv_type} ne 'V';

	    next if $info->{pool_lv} ne $scfg->{thinpool};

	    my $volid = "$storeid:$volname";

	    if ($vollist) {
		my $found = grep { $_ eq $volid } @$vollist;
		next if !$found;
	    } else {
		next if defined($vmid) && ($owner ne $vmid);
	    }

	    push @$res, {
		volid => $volid, format => 'raw', size => $info->{lv_size}, vmid => $owner,
	    };
	}
    }

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $lvname = "$scfg->{vgname}/$scfg->{thinpool}";

    $cache->{lvs} = PVE::Storage::LVMPlugin::lvm_list_volumes() if !$cache->{lvs};

    my $lvs = $cache->{lvs};

    return undef if !$lvs->{$scfg->{vgname}};

    my $info = $lvs->{$scfg->{vgname}}->{$scfg->{thinpool}};

    return undef if !$info;

    return undef if $info->{lv_type} ne 't';

    return ($info->{lv_size}, $info->{lv_size} - $info->{used}, $info->{used}, 1) if $info->{lv_size};

    return undef;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # do nothing
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # do nothing
}

# sub volume_resize {} reuse code from parent class

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	copy => { base => 1, current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname){
	$key = 'snap';
    }else{
	$key =  $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
