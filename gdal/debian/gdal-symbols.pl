#!/usr/bin/perl -w
#
# Automate symbols file updates using packages from snapshot.debian.org.
#
# Required dependencies:
#
# libfile-slurp-perl libwww-perl liburi-perl
# libjson-perl libdpkg-perl libterm-prompt-perl
# devscripts dpkg dpkg-dev binutils
# diffutils patch coreutils
#
# Copyright (C) 2013-2014, Bas Couwenberg <sebastic@debian.org>
#
# This library is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself, either Perl version 5.8.5 or,
# at your option, any later version of Perl 5 you may have available.
#

use strict;
use File::Basename;
use File::Copy;
use File::Slurp;
use Getopt::Long qw(:config bundling no_ignore_case);
use HTTP::Request::Common;
use LWP::UserAgent;
use URI::Escape;
use JSON;
use Dpkg::Version;
use Term::Prompt;

$|=1;

my $package = 'libgdal20';
my $pkgdir  = 'binary-'.$package.'/';

our $ua = LWP::UserAgent->new(agent => basename($0));

my %cfg = (
	    package    => $package,
	    version    => 'latest',
	    debsnap    => '/usr/bin/debsnap',
	    dpkgdeb    => '/usr/bin/dpkg-deb',
	    gensymbols => '/usr/bin/dpkg-gensymbols',
	    cppfilt    => '/usr/bin/c++filt',
	    objdump    => '/usr/bin/objdump',
	    diff       => '/usr/bin/diff',
	    patch      => '/usr/bin/patch',
	    sha512sum  => '/usr/bin/sha512sum',
	    pkgdir     => $pkgdir,
	    debian     => 'debian/',
	    force      => 0,
	    no_diff    => 0,
	    no_prompt  => 0,
	    yes        => 0,
	    clean      => 0,
	    verbose    => 0,
	    help       => 0,
	  );

my $result = GetOptions(
			 'p|package=s'    => \$cfg{package},
			 'V|version=s'    => \$cfg{version},
			 'S|debsnap=s'    => \$cfg{debsnap},
			 'E|dpkgdeb=s'    => \$cfg{dpkgdeb},
			 'G|gensymbols=s' => \$cfg{gensymbols},
			 'C|cppfilt=s'    => \$cfg{cppfilt},
			 'I|diff=s'       => \$cfg{diff},
			 'P|patch=s'      => \$cfg{patch},
			 'H|sha512sum=s'  => \$cfg{sha512sum},
			 'D|pkgdir=s'     => \$cfg{pkgdir},
			 'd|debian=s'     => \$cfg{debian},
			 'f|force'        => \$cfg{force},
			 'no-diff'        => \$cfg{no_diff},
			 'no-prompt'      => \$cfg{no_prompt},
			 'y|yes'          => \$cfg{yes},
			 'c|clean'        => \$cfg{clean},
			 'v|verbose'      => \$cfg{verbose},
			 'h|help'         => \$cfg{help},
		       );

if(!$result || $cfg{help} || !$cfg{package} || !$cfg{debian}) {
	print STDERR "\n" if(!$result);

	print "Usage: ". basename($0). " [OPTIONS]\n\n";
	print "Options:\n";
	print "-p, --package <NAME>      Library binary package name    ($cfg{package})\n";
	print "-V, --version <STRING>    Library binary package version ($cfg{version})\n";
	print "-S, --debsnap <PATH>      Path to debsnap                ($cfg{debsnap})\n";
	print "-E, --dpkgdeb <PATH>      Path to dpkg-deb               ($cfg{dpkgdeb})\n";
	print "-G, --gensymbols <PATH>   Path to dpkg-gensymbols        ($cfg{gensymbols})\n";
	print "-O, --objdump <PATH>      Path to objdump                ($cfg{objdump})\n";
	print "-C, --cppfilt <PATH>      Path to c++filt                ($cfg{cppfilt})\n";
	print "-I, --diff <PATH>         Path to diff                   ($cfg{diff})\n";
	print "-P, --patch <PATH>        Path to patch                  ($cfg{patch})\n";
	print "-H, --sha512sum <PATH>    Path to sha512sum              ($cfg{sha512sum})\n";
	print "-D, --pkgdir <PATH>       Path to downloaded packages    ($cfg{pkgdir})\n";
	print "-d, --debian <PATH>       Path to debian/ directory      ($cfg{debian})\n";
	print "-f, --force               Force writing into existing package directory\n";
	print "    --no-diff             Don't display diff for new symbols files\n";
	print "    --no-prompt           Don't prompt to select symbols, update manually\n";
	print "-y, --yes                 Default to yes on prompts\n";
	print "-c, --clean               Clean up temorary files after processing\n";
	print "-v, --verbose             Enable verbose output\n";
	print "-h, --help                Display this usage information\n";

	exit 1;
}

if(!-x $cfg{debsnap}) {
	print "Error: Cannot execute debsnap: $cfg{debsnap}\n";
	print "Use --debsnap to override the path and/or install the devscripts package.\n";
	exit 1;
}
if(!-x $cfg{dpkgdeb}) {
	print "Error: Cannot execute dpkg-deb: $cfg{dpkgdeb}\n";
	print "Use --dpkg-deb to override the path and/or install the dpkg package.\n";
	exit 1;
}
if(!-x $cfg{gensymbols}) {
	print "Error: Cannot execute dpkg-gensymbols: $cfg{gensymbols}\n";
	print "Use --gensymbols to override the path and/or install the dpkg-dev package.\n";
	exit 1;
}
if(!-x $cfg{objdump}) {
	print "Error: Cannot execute objdump: $cfg{objdump}\n";
	print "Use --objdump to override the path and/or install the binutils package.\n";
	exit 1;
}
if(!-x $cfg{cppfilt}) {
	print "Error: Cannot execute c++filt: $cfg{cppfilt}\n";
	print "Use --cppfilt to override the path and/or install the binutils package.\n";
	exit 1;
}
if(!-x $cfg{diff}) {
	print "Error: Cannot execute diff: $cfg{diff}\n";
	print "Use --diff to override the path and/or install the diffutils package.\n";
	exit 1;
}
if(!-x $cfg{patch}) {
	print "Error: Cannot execute patch: $cfg{patch}\n";
	print "Use --patch to override the path and/or install the patch package.\n";
	exit 1;
}
if(!-x $cfg{sha512sum}) {
	print "Error: Cannot execute sha512sum: $cfg{sha512sum}\n";
	print "Use --sha512sum to override the path and/or install the coreutils package.\n";
	exit 1;
}

if(!-r $cfg{debian} || !-w $cfg{debian}) {
	print "Error: Cannot read/write directory: $cfg{debian}\n";
	exit 1;
}
if(-e $cfg{pkgdir} && !$cfg{force}) {
	print "Error: Directory already exists: $cfg{pkgdir} (use --force to override)\n";
	exit 1;
}

$cfg{debian} .= '/' if(substr($cfg{debian}, -1, 1) ne '/');
$cfg{pkgdir} .= '/' if(substr($cfg{pkgdir}, -1, 1) ne '/');

my @versions = get_versions(%cfg);

if(!$cfg{version} || $cfg{version} eq 'latest') {
	$cfg{version} = $versions[-1];

	if(!$cfg{version}) {
		print "Error: Failed to determine latest version for: $cfg{package}\n";
		exit 1;
	}
}

my %symbols = ();

# Get binary packages for all architectures
download_packages(%cfg);
unpack_packages(%cfg);

# Update symbols files for existing architectures
create_new_symbols(%cfg);
create_new_patch_files(%cfg);
patch_new_files(%cfg);
split_new_files(%cfg);
compare_new_symbols(%cfg);

# Create symbols files for new architectures
new_architecture_symbols(%cfg);

clean_temp_files(%cfg) if($cfg{clean});

exit 0;

################################################################################
# Subroutines

sub get_versions {
	my (%args) = @_;

	my $url = 'http://snapshot.debian.org/mr/binary/'.uri_escape($args{package}).'/';
	my $req = HTTP::Request->new(GET => $url);

	print "Retrieving URL: $url ... " if($cfg{verbose});
	my $res = $ua->request($req);
	if($res->is_success) {
		print "Success\n" if($cfg{verbose});

		my $json = $res->content;
		my $data = decode_json($json);

		my @versions = ();

		if($data->{result} && @{$data->{result}}) {
			print "Checking versions...\n" if($cfg{verbose});

			foreach my $v (sort { version_compare($a->{binary_version}, $b->{binary_version}) } @{$data->{result}}) {
				push @versions, $v->{binary_version};
			}

			print "Latest version: $versions[-1]\n" if($cfg{verbose});
		}

		print "\n" if($cfg{verbose});

		return @versions;
	}
	else {
		print "Failed!\n" if($cfg{verbose});
		print "Error: Failed to retrieve URL! ($url)\n";
		print "HTTP Status: ".$res->code." ".$res->message."\n";

		return;
	}
}

sub download_packages {
	my (%args) = @_;

	my $dir = $args{pkgdir};

	if(!-e $args{pkgdir} || $args{force}) {
		if($cfg{verbose}) {
			print "Downloading binary packages for: $args{package}";
			print ", version: $args{version}"           if($args{version});
			print ", architecture: $args{architecture}" if($args{architecture});
			print ", into: $args{pkgdir}\n";
		}

		my @cmd = ();

		push @cmd, $cfg{debsnap};
		push @cmd, ('--destdir', $args{pkgdir});
		push @cmd, '--force'     if($args{force});
		push @cmd, '--verbose'   if($args{verbose});
		push @cmd, '--binary';
		push @cmd, ('--architecture', $args{architecture}) if($args{architecture});
		push @cmd, $args{package};
		push @cmd, $args{version} if($args{version} && $args{version} ne 'all');

		print "Exec: @cmd\n" if($cfg{verbose});

		my $exit = system(@cmd) >> 8;
		if($exit != 0) {
			print "Error: Command failed: @cmd ($exit)\n";
			exit $exit;
		}

		print "\n" if($cfg{verbose});
	}
	else {
		print "Error: Directory already exists: $dir (use --force to override)\n";
		return;
	}
}

sub unpack_packages {
	my (%args) = @_;

	my $dir = $args{pkgdir};

	if(-r $dir && -w $dir) {
		print "Extracting downloaded packages...\n" if($cfg{verbose});

		opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir DIR) {
			# libgdal1h_1.10.1+dfsg-1_amd64.deb
			if(/^($args{package})_(\S+)_(\S+)\.deb$/) {
				my $pkg     = $1;
				my $version = $2;
				my $arch    = $3;
				my $file    = $dir.$_;
				my $pkgdir  = $dir.$pkg.'_'.$version.'_'.$arch.'/';

				next if($arch eq 'common');
				next if($version ne $args{version} && $args{version} ne 'all');
				next if(-r $pkgdir);

				# dpkg-deb -R libgdal1h_1.10.1+dfsg-1_amd64.deb libgdal1h_1.10.1+dfsg-1_amd64

				my @cmd = (
					    $cfg{dpkgdeb},
					    '--raw-extract',
					    $file,
					    $pkgdir,
					  );

				print "Exec: @cmd\n" if($cfg{verbose});

				my $exit = system(@cmd) >> 8;
				if($exit != 0) {
					print "Error: Command failed: @cmd ($exit)\n";
					exit $exit;
				}
			}
		}
		closedir DIR;

		print "\n" if($cfg{verbose});
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		return;
	}
}

sub create_new_symbols {
	my (%args) = @_;

	my $dir = $args{debian};

	if(-r $dir && -w $dir) {
		opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir DIR) {
			# libgdal1h.symbols.amd64
			if(/^($args{package}).symbols.(\S+)$/) {
				my $pkg  = $1;
				my $arch = $2;
				my $file = $dir.$_;

				next if($arch eq 'common');
				next if($arch =~ /\.(new|diff|filt|patch|c\+\+|common|complete)$/);

				my $version = '';
				my $library = '';

				my $pkg_dir = $args{pkgdir};
				if(-r $pkg_dir) {
					print "Looking for $arch under: $pkg_dir\n" if($cfg{verbose});

					opendir(PKGDIR, $pkg_dir) || die "Error: Cannot open package directory: $pkg_dir ($!)";
					while(readdir PKGDIR) {
						# libgdal1h_1.10.1+dfsg-1_armel
						if(/^${pkg}_(\S+?)_${arch}$/) {
							print "Package directory: $_\n" if($cfg{verbose});

							$version = $1;

							next if($version ne $args{version});

							$version = upstream_version($version);

							$library = find_library(%args, dir => $pkg_dir.$_.'/usr/lib/');

							last;
						}
					}
					closedir PKGDIR;
				}
				else {
					print "Error: Cannot read package directory: $pkg_dir\n";
					print "\n" if($cfg{verbose});
					return;
				}

				if(!$version) {
					print "Error: Cannot determine library version!\n";
					print "\n" if($cfg{verbose});
					next;
				}

				if(!$library) {
					print "Error: Cannot find library!\n";
					print "\n" if($cfg{verbose});
					return;
				}

				my $output = $file.'.new';
				my $diff   = $file.'.diff';

				# dpkg-gensymbols -plibgdal1h -aarmel -v1.10.1 -Idebian/libgdal1h.symbols.armel -Odebian/libgdal1h.symbols.armel.new -ebinary-libgdal1h/libgdal1h_1.10.1+dfsg-1_armel/usr/lib/libgdal.so.1.17.1

				my @cmd = (
					    $cfg{gensymbols},
					    '-p'.$pkg,
					    '-a'.$arch,
					    '-v'.$version,
					    '-I'.$file,
					    '-O'.$output,
					    '-e'.$library,
					  );

				print "Exec: @cmd > $diff 2>&1\n" if($cfg{verbose});

				`@cmd > $diff 2>&1`;


				# cat debian/libgdal1h.symbols.armel.new | c++filt > debian/libgdal1h.symbols.armel.new.filt

				my $filt = $output.'.filt';

				print "Exec: cat $output | $cfg{cppfilt} > $filt 2>&1\n" if($cfg{verbose});

				`cat $output | $cfg{cppfilt} > $filt 2>&1`;

				# libgdal.so.1 libgdal1h #MINVER#
				# | libgdal1h #MINVER#, libgdal.so.1-1.10.1
				# #include "libgdal1h.symbols.common"

				# libgdal.so.20 libgdal20 #MINVER#
				# | libgdal20 #MINVER#, gdal-abi-2-0-0
				# #include "libgdal20.symbols.common"

				my $data = '';

				my $i = 0;
				foreach(read_file($filt)) {
					if($i == 0 && /^ /) {
						$_ = "#include \"${package}.symbols.common\"\n" . $_;
						$i++;
					}
					$data .= $_;
				}

				write_file($filt, $data);

				print "\n" if($cfg{verbose});

				$symbols{$arch}{file} = $file;
				$symbols{$arch}{new}  = $output;
				$symbols{$arch}{diff} = $diff;
				$symbols{$arch}{filt} = $filt;
			}
		}
		closedir DIR;
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		print "\n" if($cfg{verbose});
		return;
	}
}

sub find_library {
	my (%args) = @_;

	my $dir   = $args{dir};
	my $depth = $args{depth};
	   $depth = 0 if(!$depth);

	my $max_depth = 5;

	if($depth == $max_depth) {
		print "Not looking further, maximum depth reached: $depth\n" if($args{verbose});
		return;
	}

	my $library = '';

	if(-r $dir) {
		print "Reading directory: $dir\n" if($args{verbose});

		opendir(my $dh, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir $dh) {
			next if(/^\.{1,2}$/);

			my $entry = $dir.$_;

			if(-d $entry) {
				$library = find_library(%args, dir => $entry.'/', depth => $depth+1);
			}
			elsif(-f $entry && $entry =~ /\.so\.\d+\.\d+/) {
				$library = $entry;
				last;
			}
		}
		closedir $dh;

		print "Library: $library\n" if($args{verbose});
	}
	else {
		print "Error: Cannot read directory: $dir\n";
		return;
	}

	return $library;
}

sub create_new_patch_files {
	my (%args) = @_;

	# Create c++filt symbols files

	my $dir = $args{debian};

	if(-r $dir && -w $dir) {
		opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir DIR) {
			# libgdal1h.symbols.amd64
			if(/^($args{package}).symbols.(\S+)$/) {
				my $pkg  = $1;
				my $arch = $2;
				my $file = $dir.$_;

				next if($arch eq 'common');
				next if($arch =~ /\.(new|diff|filt|patch|c\+\+|common|complete)$/);

				my $diff_file  = $file.'.diff';
				my $new_file   = $file.'.new';
				my $filt_file  = $file.'.new.filt';
				my $patch_file = $file.'.new.patch';

				if(-r $diff_file && -r $new_file && -r $filt_file) {
					# Mark C++ symbols

					create_patch_file(
							   %args,
							   file1 => $new_file,
							   file2 => $filt_file,
							   patch => $patch_file,
							 );

					$symbols{$arch}{patch} = $patch_file;
				}
				else {
					print "Error: Cannot read all files: $diff_file, $new_file, $filt_file\n";
					next;
				}
			}
		}
		closedir DIR;

		print "\n" if($cfg{verbose});
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		return;
	}
}

sub create_patch_file {
	my (%args) = @_;

	return if(!$args{file1});
	return if(!$args{file2});
	return if(!$args{patch});

	my @cmd = (
		    $cfg{diff},
		    '-u',
		    $args{file1},
		    $args{file2},
		  );

	my $data = '';
	my $old  = '';
	my $new  = '';

	foreach(`@cmd`) {
		# --- debian/libgdal1h.symbols.amd64.new  2013-12-14 00:18:32.000000000 +0100
		if(/^\-\-\- (\S+\s+\d{4}.*?\S)\s*$/) {
			$old = $1;

			$_ = '';
		}
		# +++ debian/libgdal1h.symbols.amd64.new.filt     2013-12-14 01:44:01.000000000 +0100
		elsif(/^\+\+\+ (\S+\s+\d{4}.*?\S)\s*$/) {
			$new = $1;

			$_ = '--- '. $new."\n"
			   . '+++ '. $old."\n"
			   ;
		}
		# + VRTSourcedRasterBand::ComputeRasterMinMax(int, double*)@Base 1.10.1
		elsif(/^\+ (.*?) (\d+\.\d+\.\d+\S*)\s*$/) {
			$_ = '+ (c++)"'.$1.'" '.$2." 1\n";
		}
		# + VRTSourcedRasterBand::ComputeRasterMinMax(int, double*)@Base 1.10.1 1
		elsif(/^\+ (.*?) (\d+\.\d+\.\d+\S*)(\s+\d+)\s*$/) {
			$_ = '+ (c++)"'.$1.'" '.$2.$3."\n";
		}

		$data .= $_;
	}

	print "Saving rewritten patch: $args{patch}\n" if($cfg{verbose});

	write_file($args{patch}, $data);
}

sub patch_new_files {
	my (%args) = @_;

	# Apply c++filt symbols patches

	my $dir = $args{debian};

	if(-r $dir && -w $dir) {
		opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir DIR) {
			# libgdal1h.symbols.amd64
			if(/^($args{package}).symbols.(\S+)$/) {
				my $pkg  = $1;
				my $arch = $2;
				my $file = $dir.$_;

				next if($arch eq 'common');
				next if($arch =~ /\.(new|diff|filt|patch|c\+\+|common|complete)$/);

				my $diff_file  = $file.'.diff';
				my $new_file   = $file.'.new';
				my $filt_file  = $file.'.new.filt';
				my $patch_file = $file.'.new.patch';

				if(-r $diff_file && -r $new_file && -r $filt_file && -r $patch_file) {
					# Mark C++ symbols

					patch_file(
						    %args,
						    patch => $patch_file,
						    file  => $new_file,
						  );

					print "\n" if($cfg{verbose});
				}
				else {
					print "Error: Cannot read all files: $diff_file, $new_file, $filt_file, $patch_file\n";
					print "\n" if($cfg{verbose});
					next;
				}
			}
		}
		closedir DIR;
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		print "\n" if($cfg{verbose});
		return;
	}
}

sub patch_file {
	my (%args) = @_;

	my @cmd = (
		    $cfg{patch},
		    '-p1',
		    '-i'.$args{patch},
		    $args{file},
		  );

	print "Exec: @cmd\n" if($cfg{verbose});

	my $exit = system(@cmd) >> 8;
	if($exit != 0) {
		print "Error: Command failed: @cmd ($exit)\n";
		exit $exit;
	}
}

sub split_new_files {
	my (%args) = @_;

	# Split common and C++ symbols into seperate files.

	my $dir = $args{debian};

	if(-r $dir && -w $dir) {
		opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir DIR) {
			# libgdal1h.symbols.amd64
			if(/^($args{package}).symbols.(\S+)$/) {
				my $pkg  = $1;
				my $arch = $2;
				my $file = $dir.$_;

				next if($arch eq 'common');
				next if($arch =~ /\.(new|diff|filt|patch|c\+\+|common|complete)$/);

				my $diff_file  = $file.'.diff';
				my $new_file   = $file.'.new';
				my $filt_file  = $file.'.new.filt';
				my $patch_file = $file.'.new.patch';

				if(-r $diff_file && -r $new_file && -r $filt_file && -r $patch_file) {
					print "Splitting files for: $file\n" if($cfg{verbose});

					my ($common, $cplus) = split_file(
									    %args,
									    file => $new_file,
									  );

					$symbols{$arch}{common} = $common;
					$symbols{$arch}{cplus}  = $cplus;
				}
				else {
					print "Error: Cannot read all files: $diff_file, $new_file, $filt_file, $patch_file\n";
					next;
				}
			}
		}
		closedir DIR;

		print "\n" if($cfg{verbose});
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		return;
	}
}

sub split_file {
	my (%args) = @_;

	return if(!$args{file});

	if(-r $args{file}) {
		my $common = '';
		my $cplus  = '';

		foreach(read_file($args{file})) {
			if(/\(c\+\+\)/ || !/^ /) {
				$cplus  .= $_;
			}
			else {
				$common .= $_;
			}
		}

		my $common_file = $args{file}.'.common';
		my $cplus_file  = $args{file}.'.c++';

		write_file($common_file, $common);
		write_file($cplus_file,  $cplus);

		return ($common_file, $cplus_file);
	}
}

sub compare_new_symbols {
	my (%args) = @_;

	my $dir = $args{debian};

	if(-r $dir && -w $dir) {
		my %checksum = ();

		my $arch = 'common';
		my $file = $dir.$args{package}.'.symbols.'.$arch;

		print "Comparing symbols for: $file\n" if($cfg{verbose});

		if(-r $file) {
			my @items = ();
			my @files = ();

			chomp(my $sha512sum = `$cfg{sha512sum} "$file" | cut -d' ' -f1`);

			print "$sha512sum  $file\n" if($cfg{verbose});

			$checksum{$arch} = $sha512sum;

			push @items, "$sha512sum  $file";
			push @files, $file;

			my $identical = 1;
			my @different = ();

			opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
			while(readdir DIR) {
				# libgdal1h.symbols.amd64.new.common
				if(/^($args{package}).symbols.(\S+).new.common$/) {
					my $pkg2  = $1;
					my $arch2 = $2;
					my $file2 = $dir.$_;

					chomp(my $sha512sum = `$cfg{sha512sum} "$file2" | cut -d' ' -f1`);

					print "$sha512sum  $file2\n" if($cfg{verbose});

					$checksum{$arch2} = $sha512sum;

					push @items, "$sha512sum  $file2";
					push @files, $file2;

					if($checksum{common} ne $sha512sum) {
						$identical = 0;

						push @different, $file2;

						$items[-1] .= " *";
					}
				}
			}
			closedir DIR;

			if(@different) {
				print "\n" if($cfg{verbose});

				if(!$cfg{no_diff}) {
					foreach my $file2 (@different) {
						my $old = $file;
						my $new = $file2;

						my @cmd = (
							    $cfg{diff},
							    '-u',
							    $old,
							    $new,
							  );

						print "Exec: @cmd\n" if($cfg{verbose});

						my $exit = system(@cmd) >> 8;

						print "Exit: $exit\n" if($cfg{verbose});
					}
				}
			}

			if($identical) {
				print "Current $arch symbols are identical to the new symbols, no update required.\n" if($cfg{verbose});
			}
			else {
				print "New $arch symbols different from the current symbols, update required!\n" if($cfg{verbose});

				if(!$cfg{no_prompt}) {
					my $result = prompt(
							     'm',
							     {
							       prompt => "Select new symbols file to update current symbols file with:",
							       title  => "Update symbols file $file",
							       items  => \@items,
							       order  => 'down',
							       cols   => 1,
							     },
							     "[0]",
							     0,
							   );

					if($result) {
						print "New common symbols file selected: $items[$result]\n" if($cfg{verbose});

						my $file1 = $files[$result];
						my $file2 = $file;

						if(-r $file1 && -w $file2) {
							print "Copy: $file1 -> $file2\n" if($cfg{verbose});

							copy($file1, $file2) || die "Error: Failed to copy $file1 to $file2 ($!)\n";
						}
						else {
							print "Error: Cannot read $file1 and/or write $file2\n";
							return;
						}
					}
					else {
						print "Current common symbols file selected, skipping update.\n" if($cfg{verbose});
					}
				}
			}

			print "\n" if($cfg{verbose});
		}

		opendir(DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir DIR) {
			# libgdal1h.symbols.amd64
			if(/^($args{package}).symbols.(\S+)$/) {
				my $pkg  = $1;
				my $arch = $2;
				my $file = $dir.$_;

				next if($arch eq 'common');
				next if($arch =~ /\.(new|diff|filt|patch|c\+\+|common|complete)$/);

				print "Comparing symbols for: $file\n" if($cfg{verbose});

				my $old = $file;
				my $new = $file.'.new.c++';

				if(!-r $new) {
					print "Missing new $arch symbols, likely needs update later.\n" if($cfg{verbose});
				}
				else {
					chomp(my $old_sha512sum = `$cfg{sha512sum} "$old" 2> /dev/null | cut -d' ' -f1`);
					chomp(my $new_sha512sum = `$cfg{sha512sum} "$new" 2> /dev/null | cut -d' ' -f1`);

					print "$old_sha512sum  $old\n" if($cfg{verbose});
					print "$new_sha512sum  $new\n" if($cfg{verbose});

					if($old_sha512sum eq $new_sha512sum) {
						print "Current symbols are identical to the new $arch symbols, no update required.\n" if($cfg{verbose});
					}
					else {
						if(!$cfg{no_diff}) {
							my @cmd = (
								    $cfg{diff},
								    '-u',
								    $old,
								    $new,
								  );

							print "Exec: @cmd\n" if($cfg{verbose});

							my $exit = system(@cmd) >> 8;

							print "Exit: $exit\n" if($cfg{verbose});

							print `@cmd | diffstat`;
						}

						print "New $arch symbols different from the current symbols, update required!\n" if($cfg{verbose});

						if(!$cfg{no_prompt}) {
							my $help    = $cfg{yes} ? "Y/n" : "y/N";
							my $default = $cfg{yes} ? "Y"   : "N";

							my $result = prompt(
									     'y',
									     "Update symbols file for $arch?",
									     $help,
									     $default,
									   );

							if($result) {
								my $file1 = $new;
								my $file2 = $old;

								if(-r $file1 && -w $file2) {
									print "Copy: $file1 -> $file2\n" if($cfg{verbose});

									copy($file1, $file2) || die "Error: Failed to copy $file1 to $file2 ($!)\n";
								}
								else {
									print "Error: Cannot read $file1 and/or write $file2\n";
									return;
								}
							}
							else {
								print "Skipping update.\n" if($cfg{verbose});
							}
						}
					}
				}

				print "\n" if($cfg{verbose});
			}
		}
		closedir DIR;
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		print "\n" if($cfg{verbose});
		return;
	}
}

sub parse_symbols {
	my (%args) = @_;

	return if (!$args{file} || !-r $args{file});

	my %symbols = ();

	foreach(read_file($args{file})) {
		#  BSBClose@Base 1.8.0
		if(/^ (\S+)\s+(\d+\S+\d+)\s*$/) {
			my $symbol  = $1;
			my $version = $2;

			$symbols{$symbol}{version} = $version;
		}
		# libgdal.so.20 libgdal20 #MINVER#
		# | libgdal20 #MINVER#, gdal-abi-2-0-0
		# #include "libgdal20.symbols.common"
		#  (c++)"PamGetProxy(char const*)@Base" 1.8.0 1
		elsif(/^ (\S+)\s+(\d+\S+\d+)\s*(\d+)\s*$/) {
			my $symbol   = $1;
			my $version  = $2;
			my $template = $3;

			$symbols{$symbol}{version}  = $version;
			$symbols{$symbol}{template} = $template;
		}
	}

	return \%symbols;
}

sub compare_common_symbols {
	my (%args) = @_;

	return if(!$args{arch} || !$symbols{$args{arch}}{common} || !$symbols{common}{file});

	if(!$symbols{common}{symbols}) {
		$symbols{common}{symbols} = parse_symbols(%args, file => $symbols{common}{file});
	}

	$symbols{$args{arch}}{symbols} = parse_symbols(%args, file => $symbols{$args{arch}}{common});

	print "Comparing symbols between $symbols{common}{file} and $symbols{$args{arch}}{common}...\n" if($cfg{verbose});

	my %compare = ();

	foreach my $symbol (sort keys %{$symbols{common}{symbols}}) {
		$compare{$symbol}{old} = $symbols{common}{symbols}{$symbol};
	}
	foreach my $symbol (sort keys %{$symbols{$args{arch}}{symbols}}) {
		$compare{$symbol}{new} = $symbols{$args{arch}}{symbols}{$symbol};
	}

	my $changes = 0;

	foreach my $symbol (sort keys %compare) {
		if(!$compare{$symbol}{old} || !$compare{$symbol}{new}) {
			if(!$compare{$symbol}{old}) {
				print "Symbol not in old: $symbol ($symbols{common}{file})\n" if($cfg{verbose});
			}
			if(!$compare{$symbol}{new}) {
				print "Symbol not in new: $symbol ($symbols{$args{arch}}{common})\n" if($cfg{verbose});
			}

			$changes++;
		}
	}

	return $changes;
}

sub new_architecture_symbols {
	my (%args) = @_;

	my $dir = $args{pkgdir};

	if(-r $dir && -w $dir) {
		print "Creating symbols files for new architectures...\n" if($cfg{verbose});

		my $new = 0;

		opendir(my $DIR, $dir) || die "Error: Cannot open directory: $dir ($!)";
		while(readdir $DIR) {
			# libgdal1h_1.10.1+dfsg-1_amd64.deb
			if(/^($args{package})_(\S+)_(\S+)\.deb$/) {
				my $pkg     = $1;
				my $version = $2;
				my $arch    = $3;
				my $file    = $dir.$_;
				my $pkgdir  = $dir.$pkg.'_'.$version.'_'.$arch.'/';

				my $upstream_version = upstream_version($version);

				next if($symbols{$arch});

				# download all previous versions
				download_packages(%args, architecture => $arch, version => 'all');

				# unpack all previous versions
				unpack_packages(%args, architecture => $arch, version => 'all');

				# generate symbols for all versions
				foreach my $version (@versions) {
					my $library = '';

					my $pkg_dir = $args{pkgdir};
					if(-r $pkg_dir) {
						my $dir = $pkg_dir.$pkg.'_'.$version.'_'.$arch.'/';
						if(!-r $dir) {
							print "Warning: Cannot read package directory: $dir\n";
							next;
						}

						$library = find_library(%args, dir => $dir.'/usr/lib/', verbose => 0);
					}
					else {
						print "Warning: Cannot read package directory: $pkg_dir\n";
						print "\n" if($cfg{verbose});
						next;
					}

					if(!$library) {
						print "Warning: Cannot find library!\n";
						print "\n" if($cfg{verbose});
						next;
					}

					my $upstream_version = upstream_version($version);

					my $file = $args{debian}.$pkg.'.symbols.'.$arch;
					my $diff = $file.'.diff';

					# dpkg-gensymbols -plibgdal1h -aarmel -v1.10.1 -Odebian/libgdal1h.symbols.armel -ebinary-libgdal1h/libgdal1h_1.10.1+dfsg-1_armel/usr/lib/libgdal.so.1.17.1

					my @cmd = (
						    $cfg{gensymbols},
						    '-p'.$pkg,
						    '-a'.$arch,
						    '-v'.$upstream_version,
						    '-O'.$file,
						    '-e'.$library,
						  );

					print "Exec: @cmd > $diff 2>&1\n" if($cfg{verbose});

					`@cmd > $diff 2>&1`;

					$symbols{$arch}{file} = $file;
					$symbols{$arch}{diff} = $diff;
				}

				# Mark C++ symbols using c++filt
				if($symbols{$arch}{file}) {
					# cat debian/libgdal1h.symbols.armel | c++filt > debian/libgdal1h.symbols.armel.filt

					my $filt = $symbols{$arch}{file}.'.filt';

					print "Exec: cat $symbols{$arch}{file} | $cfg{cppfilt} > $filt 2>&1\n" if($cfg{verbose});

					`cat $symbols{$arch}{file} | $cfg{cppfilt} > $filt 2>&1`;

					# libgdal.so.1 libgdal1h #MINVER#
					# | libgdal1h #MINVER#, libgdal.so.1-1.10.1
					# #include "libgdal1h.symbols.common"

					# libgdal.so.20 libgdal20 #MINVER#
					# | libgdal20 #MINVER#, gdal-abi-2-0-0
					# #include "libgdal20.symbols.common"

					my $data = '';

					my $upstream_version = upstream_version($versions[-1]);

					(my $abi = $upstream_version) =~ s/\./-/g;
					$abi =~ s/\~\w+$//;

					my $i = 0;
					foreach(read_file($filt)) {
						if($i == 0 && /^ /) {
							$_ = "#include \"${pkg}.symbols.common\"\n" . $_;
							$_ = "| ${pkg} #MINVER#, gdal-abi-$abi\n" . $_;

							$i++;
						}

						$data .= $_;
					}

					write_file($filt, $data);

					print "\n" if($cfg{verbose});

					$symbols{$arch}{filt} = $filt;
				}

				# Create & apply patch file for enhanced C++ symbols
				if($symbols{$arch}{file} && $symbols{$arch}{filt}) {
					my $patch_file = $symbols{$arch}{file}.'.patch';

					create_patch_file(
							   %args,
							   file1 => $symbols{$arch}{file},
							   file2 => $symbols{$arch}{filt},
							   patch => $patch_file,
							 );

					patch_file(
						    %args,
						    patch => $patch_file,
						    file  => $symbols{$arch}{file},
						  );

					$symbols{$arch}{patch} = $patch_file;
				}

				# split common & C++ symbols
				if($symbols{$arch}{file} && $symbols{$arch}{filt} && $symbols{$arch}{patch}) {
					my ($common, $cplus) = split_file(
									    %args,
									    file => $symbols{$arch}{file},
									  );

					$symbols{$arch}{common} = $common;
					$symbols{$arch}{cplus}  = $cplus;
				}

				# compare with existing common symbols
				if($symbols{$arch}{file} && $symbols{$arch}{common} && $symbols{$arch}{cplus}) {
					if(!$symbols{common}{file}) {
						$symbols{common}{file} = $args{debian}.$args{package}.'.symbols.common';
					}

					my $changes = compare_common_symbols(
									      %args,
									      arch => $arch,
									    );

					if(!$changes) {
						print "Current common symbols are identical to the $arch common symbols, no update required.\n" if($cfg{verbose});

						# Replace architecture symbols file with C++ symbols only

						my $file1 = $symbols{$arch}{cplus};
						my $file2 = $symbols{$arch}{file};

						if(-r $file1 && -w $file2) {
							print "Copy: $file1 -> $file2\n" if($cfg{verbose});

							copy($file1, $file2) || die "Error: Failed to copy $file1 to $file2 ($!)\n";
						}
						else {
							print "Warning: Cannot read $file1 and/or write $file2\n";
							next;
						}
					}
					else {
						print "New $arch common symbols different from the current common symbols, update required!\n" if($cfg{verbose});
					}
				}

				$new++;

				print "\n" if($cfg{verbose});
			}
		}
		closedir $DIR;

		print "No new architectures found.\n" if(!$new && $cfg{verbose});
	}
	else {
		print "Error: Cannot read/write directory: $dir\n";
		return;
	}
}

sub clean_temp_files {
	my (%args) = @_;

	print "Removing files:\n" if($cfg{verbose});

	my $i = 0;	
	foreach my $arch (sort keys %symbols) {
		next if($arch eq 'common');

		foreach my $key (sort keys %{$symbols{$arch}}) {
			next if($key eq 'file' || $key eq 'symbols' || !-r $symbols{$arch}{$key});

			print " $symbols{$arch}{$key}" if($cfg{verbose});
			
			unlink($symbols{$arch}{$key}) || die "Error: Failed to unlink: $symbols{$arch}{$key} ($!)";
		}

		$i++;

		print "\n" if($cfg{verbose});
	}

	print "\n" if($cfg{verbose});
}

sub upstream_version {
	my $version = shift;

	$version =~ s/(\+dfsg\d*)?-\d+(\~\w+)?(\+b\d+)?$//;

	return $version;
}

