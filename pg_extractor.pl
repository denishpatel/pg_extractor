#!/usr/bin/env perl
use strict;
use warnings;

# PGExtractor, a script for doing advanced dump filtering and managing schema for PostgreSQL databases
# Copyright 2011, OmniTI, Inc. (http://www.omniti.com/)
# See complete license and copyright information at the bottom of this script
# For newer versions of this script, please see:
# https://github.com/omniti-labs/pg_extractor
# POD Documentation also available by issuing pod2text pg_extractor.pl


use DirHandle;
use English qw( -no_match_vars);
use File::Copy;
use File::Path 'mkpath';
use File::Spec;
use File::Temp;
use Getopt::Long qw( :config no_ignore_case );
use Sys::Hostname;
use Pod::Usage;
use Cwd;

my ($excludeschema_dump, $includeschema_dump, $excludetable_dump, $includetable_dump) = ("","","","");
my (@includeview, @excludeview);
my (@includefunction, @excludefunction);
my (@includeowner, @excludeowner);
my (@regex_incl, @regex_excl);
my (@tablelist, @viewlist, @functionlist, @typelist, @acl_list, @commentlist);


################ Run main program subroutines
#my $start_time = time();
#sub elapsed_time { return time() - $start_time; }

my $O = get_options();

set_config();

create_dirs();
my $dmp_tmp_file = File::Temp->new( TEMPLATE => 'pg_extractor_XXXXXXX',
                                    SUFFIX => '.tmp',
                                    DIR => ( File::Spec->tmpdir || $O->{'basedir'} ));

if ($O->{'gettables'} || $O->{'getfuncs'} || $O->{'getviews'} || $O->{'gettypes'}) {
    print "Creating temp dump...\n" if !$O->{'quiet'};
    create_temp_dump();

    print "Building object lists...\n" if !$O->{'quiet'};
    build_object_lists();


    if (@tablelist) {
        print "Creating table ddl files...\n" if !$O->{'quiet'};
        create_ddl_files(\@tablelist, "table");
    }

    if (@viewlist) {
        print "Creating view ddl files...\n" if !$O->{'quiet'};
        create_ddl_files(\@viewlist, "view");
    }

    if (@functionlist) {
        print "Creating function ddl files...\n" if !$O->{'quiet'};
        create_ddl_files(\@functionlist, "function");
    }

    if (@typelist) {
        print "Creating type ddl files...\n" if !$O->{'quiet'};
        create_ddl_files(\@typelist, "type");
    }
}

if ($O->{'getroles'}) {
     print "Creating role ddl file...\n" if !$O->{'quiet'};
    create_role_ddl();
}

if ($O->{'sqldump'}) {
    print "Creating pg_dump file...\n" if !$O->{'quiet'};
    copy_sql_dump();
}

if ($O->{'svn'}) {
    svn_commit();
}

if ($O->{'git'} || $O->{'gitpush'}) {
    git_commit();
}

# If svndel is set, it will take care of cleaning up the unwanted files when it removes them from svn
if ($O->{'delete'} && !$O->{'svndel'}) {
    print "Deleting files for objects that are not part of desired export...\n" if !$O->{'quiet'};
    delete_files();
}

print "Cleaning up...\n" if !$O->{'quiet'};
cleanup();

exit;
#print "Cleaned up and finished exporting $dbname ddl after " . elapsed_time() . " seconds.\n";
############################


# TODO See if it's possible to dump objects that a user has any (maybe some?) permissions on.
sub get_options {
    my %o = (
        'pgdump' => "pg_dump",
        'pgrestore' => "pg_restore",
        'pgdumpall' => "pg_dumpall",
        'basedir' => ".",

        'svncmd' => 'svn',
        'gitcmd' => 'git',
        'commitmsg' => 'Pg ddl updates',
    );
   pod2usage(-msg => "Syntax error", -exitval => 2, verbose => 99, -sections => "SYNOPSIS|OPTIONS" ) unless GetOptions(
        \%o,
        'basedir|ddlbase=s',
        'username|U=s',
        'host|h=s',
        'hostname=s',
        'port|p=i',
        'pgpass=s',
        'dbname|d=s',
        'pgdump=s',
        'pgrestore=s',
        'pgdumpall=s',
        'quiet!',
        'gettables!',
        'getviews!',
        'getfuncs!',
        'gettypes!',
        'getroles!',
        'getall!',
        'getdata!',
        'Fc!',
        'sqldump!',
        'N=s',
        'N_file=s',
        'n=s',
        'n_file=s',
        'T=s',
        'T_file=s',
        't=s',
        't_file=s',
        'V=s',
        'V_file=s',
        'v=s',
        'v_file=s',
        'P_file=s',
        'p_file=s',
        'O=s',
        'o=s',
        'O_file=s',
        'o_file=s',
        'encoding=s',
        'no-owner!',
        'inserts!',
        'column-inserts|attribute-inserts!',
        'no-acl|no-privileges!',
        'regex_incl_file=s',
        'regex_excl_file=s',
        'delete!',

        'svn!',
        'svn_userfile=s',
        'svndel!',
        'svncmd=s',

        'git!',
        'gitdel!',
        'gitpush!',
        'gitcmd=s',
        'commitmsg=s',
        'commitmsgfn=s',

        'help|?',

    );
    pod2usage(-exitval => 0, -verbose => 2, -noperldoc) if $o{'help'};
    return \%o;
}

sub set_config {

    if ($O->{'dbname'}) {
        $ENV{PGDATABASE} = $O->{'dbname'};
    }
    if ($O->{'port'}) {
        $ENV{PGPORT} = $O->{'port'};
    }
    if ($O->{'host'}) {
        $ENV{PGHOST} = $O->{'host'};
    }
    if ($O->{'username'}) {
        $ENV{PGUSER} = $O->{'username'};
    }
    if ($O->{'pgpass'}) {
        $ENV{PGPASSFILE} = $O->{'pgpass'};
    }
    if ($O->{'encoding'}) {
        $ENV{PGCLIENTENCODING} = $O->{'encoding'};
    }

    if (!$O->{'gettables'} && !$O->{'getfuncs'} && !$O->{'getviews'} && !$O->{'gettypes'} && !$O->{'getroles'}) {
        if ($O->{'getall'}) {
            $O->{'gettables'} = 1;
            $O->{'getfuncs'} = 1;
            $O->{'getviews'} = 1;
            $O->{'gettypes'} = 1;
            $O->{'getroles'} = 1;
        } else {
            die("NOTICE: No output options set. Please set one or more of the following: --gettables, --getviews, --getprocs, --gettypes, --getroles. Or --getall for all. Use --help to show all options\n");
        }
    }

    if (!$O->{'gettables'} && ($O->{'T'} || $O->{'T_file'} || $O->{'t'} || $O->{'t_file'})) {
        die "Cannot include/exclude tables without setting option to export tables (--gettables or --getall).\n";
    }

    if (!$O->{'getviews'} && ($O->{'V'} || $O->{'V_file'} || $O->{'v'} || $O->{'v_file'})) {
        die "Cannot include/exclude views without setting option to export views (--getviews or --getall).\n";
    }

    if (!$O->{'getfuncs'} && ($O->{'P_file'} || $O->{'p_file'})) {
        die "Cannot include/exclude functions without setting option to export functions (--getfuncs or --getall).\n";
    }

    #TODO for some reason not having getdata will not fire this exception.
    if ( (!$O->{'getdata'} || !$O->{'gettables'}) && ($O->{'inserts'} || $O->{'column-inserts'} ) ) {
        die "Must set --gettables or --getall if using --inserts or --column-inserts.\n";
    }


    # TODO Redo option combinations to work like check_postgres (exclude then include)
    #      Until then only allowing one or the other
    if ( (($O->{'n'} && $O->{'N'}) || ($O->{'n_file'} && $O->{'N_file'})) ||
            (($O->{'t'} && $O->{'T'}) || ($O->{'t_file'} && $O->{'T_file'})) ||
            (($O->{'v'} && $O->{'V'}) || ($O->{'v_file'} && $O->{'V_file'})) ||
            (($O->{'p_file'} && $O->{'P_file'})) ) {
        die "Cannot specify both include and exclude for the same object type (schema, table, view, function).\n";
    }

    if ($O->{'svndel'} && !$O->{'svn'}) {
        die "Cannot specify svn deletion without --svn option.\n";
    }

    if ( $O->{'git'} && $O->{'gitpush'} ) {
        die "Use either --git or --gitpush. --gitpush will do a local commit as well as a remote push";
    }

    #TODO if gitdel is set and neither git nor gitpush is set, error out

    chdir $O->{'basedir'};
    my $workingdir = cwd();
    my $real_server_name=hostname;
    my $customhost;
    if ($O->{'hostname'}) {
        $customhost = $O->{'hostname'};
    } else {
        chomp ($customhost = $real_server_name);
    }
    $O->{'basedir'} = File::Spec->catdir($workingdir, $customhost, $ENV{PGDATABASE});


    if ($O->{'N'} || $O->{'N_file'} || $O->{'T'} || $O->{'T_file'} ||
            $O->{'V'} || $O->{'V_file'} || $O->{'P_file'} || $O->{'O'} || $O->{'O_file'} || $O->{'regex_excl_file'}) {
        print "Building exclude lists...\n" if !$O->{'quiet'};
        build_excludes();
    }
    if ($O->{'n'} || $O->{'n_file'} || $O->{'t'} || $O->{'t_file'} ||
            $O->{'v'} || $O->{'v_file'} || $O->{'p_file'} || $O->{'o'} || $O->{'o_file'} || $O->{'regex_incl_file'}) {
        print "Building include lists...\n" if !$O->{'quiet'};
        build_includes();
    }

}

sub create_dirs {
    my $newdir = shift @_;

    my $destdir = File::Spec->catdir($O->{'basedir'}, $newdir);
    if (!-e $destdir) {
       eval { mkpath($destdir) };
       if ($@) {
            die_cleanup("Couldn't create base directory [$O->{basedir}]: $@");
        }
       print "created directory target [$destdir]\n" if !$O->{'quiet'};
    }
    return $destdir;
}

sub create_temp_dump {
    my $pgdumpcmd = "$O->{pgdump} -Fc ";

    #if not getting data or don't need a separate copy of dump file,
    # no need to put more than just the schema in the temp dump
    if (!$O->{'getdata'} || !$O->{'sqldump'}) {
        $pgdumpcmd .= "-s ";
    }
    if ($O->{'N'} || $O->{'N_file'}) {
        $pgdumpcmd .= "$excludeschema_dump ";
    }
    if ($O->{'n'} || $O->{'n_file'}) {
        $pgdumpcmd .= "$includeschema_dump ";
    }
    if ($O->{'T'} || $O->{'T_file'}) {
        $pgdumpcmd .= "$excludetable_dump ";
    }
    if ($O->{'t'} || $O->{'t_file'}) {
        $pgdumpcmd .= "$includetable_dump ";
    }
    if ($O->{'no-acl'}) {
        $pgdumpcmd .= " --no-acl ";
    }

    print "$pgdumpcmd > $dmp_tmp_file\n" if !$O->{'quiet'};
    system "$pgdumpcmd > $dmp_tmp_file";
}

sub build_filter_list {
    my $list = shift;
    my $dump_option = shift;
    my (@list, $dumplist);
    if ($list =~ /,/) {
        @list = split(',', $list);
        if (defined($dump_option)) {
            $dumplist .= "-" . $dump_option . $_ . " " for @list;
            return $dumplist;
        } else {
            return @list;
        }
    } else {
        if (defined($dump_option)) {
            $dumplist = "-". $dump_option . $list;
            return $dumplist;
        } else {
            push @list, $list;
            return @list;
        }
    }
}

sub built_filter_list_file {
    my $file = shift;
    my $dump_option = shift;
    my (@list, $list);
    open my $fh, "<", $file or die_cleanup("Cannot open filter file for reading [$file]: $!");
    while (my $line = <$fh>) {
        chomp($line);
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        if (defined($dump_option)) {
            $list .= "-" . $dump_option . $line . " ";
        } else {
            push @list, $line;
        }
    }
    close $fh;
    if (defined($dump_option)) {
        return $list;
    } else {
        return @list;
    }
}

sub build_excludes {

    $excludeschema_dump = build_filter_list($O->{'N'}, "N") if (defined($O->{'N'}));
    $excludetable_dump = build_filter_list($O->{'T'}, "T") if (defined($O->{'T'}));
    @excludeview = build_filter_list($O->{'V'}) if (defined($O->{'V'}));
    @excludeowner = build_filter_list($O->{'O'}) if (defined($O->{'O'}));

    $excludeschema_dump = built_filter_list_file($O->{'N_file'}, "N") if ($O->{'N_file'});
    $excludetable_dump = built_filter_list_file($O->{'T_file'}, "T") if ($O->{'T_file'});

    @excludeview = built_filter_list_file($O->{'V_file'}) if ($O->{'V_file'});
    @excludefunction = built_filter_list_file($O->{'P_file'}) if ($O->{'P_file'});
    @excludeowner = built_filter_list_file($O->{'O_file'}) if ($O->{'O_file'});
    @regex_excl = built_filter_list_file($O->{'regex_excl_file'}) if ($O->{'regex_excl_file'});
}

sub build_includes {

    $includeschema_dump = build_filter_list($O->{'n'}, "n") if (defined($O->{'n'}));
    $includetable_dump = build_filter_list($O->{'t'}, "t") if (defined($O->{'t'}));
    @includeview = build_filter_list($O->{'v'}) if (defined($O->{'v'}));
    @includeowner = build_filter_list($O->{'o'}) if (defined($O->{'o'}));

    $includeschema_dump = built_filter_list_file($O->{'n_file'}, "n") if ($O->{'n_file'});
    $includetable_dump = built_filter_list_file($O->{'t_file'}, "t") if ($O->{'t_file'});

    @includeview = built_filter_list_file($O->{'v_file'}) if ($O->{'v_file'});
    @includefunction = built_filter_list_file($O->{'p_file'}) if ($O->{'p_file'});
    @includeowner = built_filter_list_file($O->{'o_file'}) if ($O->{'o_file'});
    @regex_incl = built_filter_list_file($O->{'regex_incl_file'}) if ($O->{'regex_incl_file'});
}

sub build_object_lists {
    my $restorecmd = "$O->{pgrestore} -l $dmp_tmp_file";
    my ($objid, $objtype, $objschema, $objsubtype, $objname, $objowner, $key, $value);


    RESTORE_LABEL: foreach (`$restorecmd`) {
        chomp;
        if (/^;/) {
            next;
        }
        #print "restorecmd result: $_ \n";
        my ($typetest) = /\d+;\s\d+\s\d+\s+(.*)/;
        if ($typetest =~ /^TABLE|VIEW|TYPE/) {
            # avoid output error when table data is being exported
            if ($typetest =~ /^TABLE/) {
                if ( /\d+;\s\d+\s\d+\sTABLE\sDATA\s\S+\s\S+\s\S+/ ) {
                    next RESTORE_LABEL;
                }
            }
            ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(\S+)\s(\S+)/;
        } elsif ($typetest =~ /^ACL/) {
            if (/\(.*\)/) {
                ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(.*\))\s(\S+)/;
            } else {
                ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(\S+)\s(\S+)/;
            }
            next RESTORE_LABEL if $objtype eq "-";
        } elsif ($typetest =~ /^FUNCTION|AGGREGATE/) {
            ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(.*\))\s(\S+)/;
        } elsif ($typetest =~ /^COMMENT/) {

            ($objsubtype) = /\d+;\s\d+\s\d+\s\S+\s\S+\s(\S+)/;

            if ($objsubtype eq "FUNCTION" || $objsubtype eq "AGGREGATE") {

                # pg_restore -l adds the variable name into the COMMENT function signature if variable names are used in the parameter list,
                # but it doesn't put them in the signature of the function itself.
                # If the function definition contains the variable names to be used, then it's nearly impossible to split out
                # argument types from the variable name so it can match against the actual function definition.
                # See about talking to Postgres devs about why the variable name is being included only in COMMENTS.

                # Maybe make a separate comment file for functions?

                ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s\S+\s(.*\))\s(\S+)/;

            } elsif ($objsubtype eq "VIEW" || $objsubtype eq "TYPE") {
                ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s\S+\s(\S+)\s(\S+)/;
            } else {
                next RESTORE_LABEL;
            }
        } else {
            next RESTORE_LABEL;
        }

        if (@excludeowner) {
            foreach my $o (@excludeowner) {
                next RESTORE_LABEL if ($o eq $objowner);
            }
        }

        if (@includeowner) {
            foreach my $o (@includeowner) {
                next RESTORE_LABEL if ($o ne $objowner);
            }
        }

        if (@regex_excl) {
            foreach my $r (@regex_excl) {
                next RESTORE_LABEL if ($objname =~ /$r/);
            }
        }

        if (@regex_incl) {
            foreach my $r (@regex_incl) {
                next RESTORE_LABEL unless ($objname =~ /$r/);
            }
        }

        if ($O->{'gettables'} && $objtype eq "TABLE") {
            push @tablelist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($O->{'getviews'} && $objtype eq "VIEW") {
            if (@excludeview) {
                foreach (@excludeview) {
                    if ($_ =~ /\./) {
                        next RESTORE_LABEL if($_ eq "$objschema.$objname");
                    } elsif ($_ eq $objname) {
                        next RESTORE_LABEL;
                    }
                }
            }
            if (@includeview) {
                my $found = 0;
                foreach my $i (@includeview) {
                    if ($i =~ /\./) {
                         if($i ne "$objschema.$objname") {
                            next;
                         } else {
                            $found = 1;
                         }
                    } else {
                        if ($i ne $objname) {
                            next;
                        } else {
                            $found = 1;
                        }
                    }
                }
                if (!$found) {
                    next RESTORE_LABEL;
                }
            }
            push @viewlist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($O->{'getfuncs'} && ($objtype eq "FUNCTION" || $objtype eq "AGGREGATE")) {
            if (@excludefunction) {
                foreach my $e (@excludefunction) {
                    if ($e =~ /\./) {
                        next RESTORE_LABEL if($e eq "$objschema.$objname");
                    } elsif ($e eq $objname) {
                        next RESTORE_LABEL;
                    }
                }
            }

            if (@includefunction) {
                my $found = 0;
                foreach my $i (@includefunction) {
                    if ($i =~ /\./) {
                         if($i ne "$objschema.$objname") {
                            next;
                         } else {
                            $found = 1;
                         }
                    } else {
                        if ($i ne $objname) {
                            next;
                        } else {
                            $found = 1;
                        }
                    }
                }
                if (!$found) {
                    next RESTORE_LABEL;
                }
            }
            push @functionlist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($O->{'gettypes'} && $objtype eq "TYPE") {
            push @typelist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($objtype eq "COMMENT") {

            push @commentlist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "subtype" => $objsubtype,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($objtype eq "ACL") {
            push @acl_list, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }
    } # end restorecmd if
} # end build_object_lists


sub create_ddl_files {
    my (@objlist) = (@{$_[0]});
    my $destdir = $_[1];
    my ($restorecmd, $pgdumpcmd, $fqfn, $funcname, $format);
    my $fulldestdir = create_dirs($destdir);
    my $tmp_ddl_file = File::Temp->new( TEMPLATE => 'pg_extractor_XXXXXXXX',
                                        SUFFIX => '.tmp',
                                        DIR => $O->{'basedir'});
    my $list_file_contents = "";
    my $offset = 0;
    if ($O->{'Fc'}) {
        $format = '-Fc';
    } else {
        $format = '-Fp';
    }
    if (!$O->{'getdata'}) {
        $format .= " -s";
    }

    foreach my $t (@objlist) {

        print "restore item: $t->{id} $t->{type} $t->{schema} $t->{name} $t->{owner}\n" if !$O->{'quiet'};

        if ($t->{'name'} =~ /\(.*\)/) {
            $funcname = substr($t->{'name'}, 0, index($t->{'name'}, "\("));
            my $schemafile = $t->{'schema'};
            # account for special characters in object name
            $schemafile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;
            $funcname =~ s/(\W)/sprintf(",%02x", ord $1)/ge;
            $fqfn = File::Spec->catfile($fulldestdir, "$schemafile.$funcname");
        } else {
            my $schemafile = $t->{'schema'};
            my $namefile = $t->{'name'};
            # account for special characters in object name
            $schemafile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;
            $namefile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;
            $fqfn = File::Spec->catfile($fulldestdir, "$schemafile.$namefile");
        }

        $list_file_contents = "$t->{id} $t->{type} $t->{schema} $t->{name} $t->{owner}\n";

        if ($t->{'type'} eq "TABLE") {
            #TODO see if there's a better way to handle this. Seems sketchy but works for now
            # extra quotes to keep the shell from eating the doublequotes & allow for mixed case or special chars
            $pgdumpcmd = "$O->{pgdump} $format --table=\'\"$t->{schema}\"\'.\'\"$t->{name}\"\'";
            if ($O->{'inserts'}) {
                $pgdumpcmd .= " --inserts ";
            }
            if ($O->{'column-inserts'}) {
                $pgdumpcmd .= " --column-inserts ";
            }
            if ($O->{'no-owner'}) {
                $pgdumpcmd .= " --no-owner ";
            }
            if ($O->{'no-acl'}) {
                $pgdumpcmd .= " --no-acl ";
            }
            $pgdumpcmd .= " > $fqfn.sql";
            system $pgdumpcmd;
        } else {
            # TODO this is a mess but, amazingly, it works. try and tidy up if possible.
            # put all functions with same basename in the same output file
            # along with each function's ACL & COMMENT following just after it (see note in COMMENT parsing section above).
            if ($t->{'type'} eq "FUNCTION" || $t->{'type'} eq "AGGREGATE") {
                my @dupe_objlist = @objlist;
                my $dupefunc;
                # add to current file output if first found object has an ACL or comment
                foreach my $a (@acl_list) {
                    if ($a->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$a->{id} $a->{type} $a->{schema} $a->{name} $a->{owner}\n";
                    }
                }
                foreach my $c (@commentlist) {
                    if ($c->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$c->{id} $c->{type} $c->{schema} $c->{subtype} $c->{name} $c->{owner}\n";
                    }
                }
                # loop through dupe of objlist to find overloads
                foreach my $d (@dupe_objlist) {
                    $dupefunc = substr($d->{'name'}, 0, index($d->{'name'}, "\("));
                    # if there is another function with the same name in the same schema, but different signature, as this one ($t)...
                    if ($funcname eq $dupefunc && $t->{'schema'} eq $t->{'schema'} && $t->{'name'} ne $d->{'name'}) {
                        # ...add overload of function ($d) to current file output
                        $list_file_contents .= "$d->{id} $d->{type} $d->{schema} $d->{name} $d->{owner}\n";
                        # add overloaded function's ACL if it exists
                        foreach my $a (@acl_list) {
                            if ($a->{'name'} eq $d->{'name'}) {
                                $list_file_contents .= "$a->{id} $a->{type} $a->{schema} $a->{name} $a->{owner}\n";
                            }
                        }
                        foreach my $c (@commentlist) {
                            if ($c->{'name'} eq $d->{'name'}) {
                                $list_file_contents .= "$c->{id} $c->{type} $c->{schema} $c->{subtype} $c->{name} $c->{owner}\n";
                            }
                        }
                        # if overload found, remove from main @objlist so it doesn't get output again.
                        splice(@objlist,$offset,1)
                    }
                }
            } else {

                # add to current file output if this object has an ACL
                foreach my $a (@acl_list) {
                    if ($a->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$a->{id} $a->{type} $a->{schema} $a->{name} $a->{owner}\n";
                    }
                }
                foreach my $c (@commentlist) {
                    if ($c->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$c->{id} $c->{type} $c->{schema} $c->{subtype} $c->{name} $c->{owner}\n";
                    }
                }
            }
            open LIST, ">", $tmp_ddl_file or die_cleanup("could not create required temp file [$tmp_ddl_file]: $!\n");
            print "$list_file_contents\n" if !$O->{'quiet'};
            print LIST "$list_file_contents";
            $restorecmd = "$O->{pgrestore} -L $tmp_ddl_file -f $fqfn.sql ";
            if ($O->{'no-owner'}) {
                $restorecmd .= " --no-owner ";
            }
            $restorecmd .= " $dmp_tmp_file";
            ##print "final restore command: $restorecmd\n";
            system $restorecmd;
            close LIST;
        }
        chmod 0664, $fqfn;
        $offset++;
    }  # end @objlist foreach
}

sub create_role_ddl {
    my $rolesdir = create_dirs('role');
    my $filepath = File::Spec->catfile($rolesdir, "roles_dump.sql");

    open my $fh, '-|', "$O->{pgdumpall} --version" or die "Cannot read from $O->{pgdumpall} --version: $OS_ERROR";
    my $version_info = <$fh>;
    close $fh;

    my @version_elements = $version_info =~ m{(\d+)}g;
    my $version = sprintf '%03d%03d', @version_elements[0,1];

    my $roles_option = $version < '008003' ? '--globals-only' : '--roles-only';

    my $dumprolecmd = "$O->{pgdumpall} $roles_option > $filepath";
    system $dumprolecmd;
}

sub copy_sql_dump {
    my $dump_folder = create_dirs("pg_dump");
    my $pgdumpfile = File::Spec->catfile($dump_folder, "$ENV{PGDATABASE}_pgdump.pgr");
    copy ($dmp_tmp_file->filename, $pgdumpfile);
}

#TODO add commands to cleanup empty folders
sub delete_files {
    my @files_to_delete = files_to_delete();
    foreach my $f (@files_to_delete) {
        unlink $f or warn "Unable to delete file $f: $!\n";
    }
}


# TODO account for objects with special characters in name
# Get a list of the files on disk to remove from disk. Kept as separate function so SVN/Git can use to delete files from VCS as well.
sub files_to_delete {
    my %file_list;
    my $dirh;

    # If directory exists, check it to see if the files it contains match what is contained in @objectlist previously created
    if ( ($dirh = DirHandle->new($O->{'basedir'}."/table")) ) {
        while (defined(my $d = $dirh->read())) {
            if ($d =~ /,/) {
                # convert special characters back to ASCII character
                $d =~ s/,(\w\w)/chr(hex($1))/ge;
            }
            $file_list{"table/$d"} = 1 if (-f "$O->{basedir}/table/$d" && $d =~ m/\.sql$/o);
        }
        # Go through the list of table found in the database and remove the corresponding entry from the file_list.
        foreach my $f (@tablelist) {
            delete($file_list{"table/$f->{schema}.$f->{name}.sql"});
        }
    }

    if ( ($dirh = DirHandle->new($O->{'basedir'}."/function")) ) {
        while (defined(my $d = $dirh->read())) {
            if ($d =~ /,/) {
                $d =~ s/,(\w\w)/chr(hex($1))/ge;
            }
            $file_list{"function/$d"} = 1 if (-f "$O->{basedir}/function/$d" && $d =~ m/\.sql$/o);
        }
        foreach my $f (@functionlist) {
            my $funcname = substr($f->{'name'}, 0, index($f->{'name'}, "\("));
            delete($file_list{"function/$f->{schema}.$funcname.sql"});
        }
    }

    if ( ($dirh = DirHandle->new($O->{'basedir'}."/view")) ) {
        while (defined(my $d = $dirh->read())) {
            if ($d =~ /,/) {
                $d =~ s/,(\w\w)/chr(hex($1))/ge;
            }
        	$file_list{"view/$d"} = 1 if (-f "$O->{basedir}/view/$d" && $d =~ m/\.sql$/o);
        }
        foreach my $f (@viewlist) {
        	delete($file_list{"view/$f->{schema}.$f->{name}.sql"});
        }
    }

    if ( ($dirh = DirHandle->new($O->{'basedir'}."/type")) ) {
        while (defined(my $d = $dirh->read())) {
            if ($d =~ /,/) {
                $d =~ s/,(\w\w)/chr(hex($1))/ge;
            }
        	$file_list{"type/$d"} = 1 if (-f "$O->{basedir}/type/$d" && $d =~ m/\.sql$/o);
        }
        foreach my $f (@typelist) {
        	delete($file_list{"type/$f->{schema}.$f->{name}.sql"});
        }
    }

    if (!defined($O->{'sqldump'}) && ($dirh = DirHandle->new($O->{'basedir'}."/pg_dump")) ) {
        while (defined(my $d = $dirh->read())) {
        	$file_list{"pg_dump/$d"} = 1 if (-f "$O->{basedir}/pg_dump/$d" && $d =~ m/pgdump\.pgr$/o);
        }
    }

    if (!defined($O->{'getroles'}) && ($dirh = DirHandle->new($O->{'basedir'}."/role")) ) {
        while (defined(my $d = $dirh->read())) {
        	$file_list{"role/$d"} = 1 if (-f "$O->{basedir}/role/$d" && $d =~ m/\.sql$/o);
        }
    }

    # The files that are left in the %file_list are those for which the object that they represent has been removed or is no longer desired.
    my @files = map { "$O->{basedir}/$_" } keys(%file_list);
    return @files;
}

sub git_commit {
    my (@git_add, @git_ignored);
    chdir $O->{'basedir'};
    #TODO need to rework how the basedir is set. Then note in the help tha for git/svn that the base repository
    # folder is /basedir/hostname, not /basedir/hostname/dbname (which is sort of how svn is working now)
    chdir "../";
    my $git_stat_cmd = "$O->{gitcmd} status --porcelain";
    foreach my $s (`$git_stat_cmd`) {
        if ($s !~ /\.sql$|.pgr$/) {
            push @git_ignored, $s;
            next;
        }
        if ($s =~ /^\?\?\s+(\S+)$/) {
            push @git_add, $1;
        }
    }

    foreach my $i (@git_ignored) {
        print "ignored: $i" if !$O->{'quiet'};
    }

    foreach my $a (@git_add) {
        my $git_add_cmd = "$O->{gitcmd} add $a";
        print "$git_add_cmd\n" if !$O->{'quiet'};
        system $git_add_cmd;
    }

    if ($O->{'gitdel'}) {
        my @files_to_delete = files_to_delete();
        if (scalar(@files_to_delete > 0)) {
            foreach my $d (@files_to_delete) {
                my $git_del_cmd = "$O->{gitcmd} rm $d";
                print "$git_del_cmd\n" if !$O->{'quiet'};
                system $git_del_cmd;
            }
        } else {
            print "No files to delete from Git\n" if !$O->{'quiet'};
        }
    }


    #Put commit message in external file to avoid issues with any special characters in it
    my $git_commit_msg_file;
    if ($O->{'commitmsgfn'}) {
        $git_commit_msg_file = $O->{'commitmsgfn'};
    } else {
        $git_commit_msg_file = File::Temp->new( TEMPLATE => 'pg_extractor_XXXXXXX',
                                    SUFFIX => '.tmp',
                                    DIR => $O->{'basedir'});
        print $git_commit_msg_file $O->{'commitmsg'};
    }

    my $git_commit_cmd = "$O->{gitcmd} commit -a -F $git_commit_msg_file";
    print "$git_commit_cmd\n" if !$O->{'quiet'};
    system $git_commit_cmd;

    if ($O->{'gitpush'}) {
        system "$O->{gitcmd} push";
    }
}

sub svn_commit {

    my (@svn_add, @svn_ignored);
    my $svnuser = " ";
    if ($O->{'svn_userfile'}) {
        open my $fh, "<", $O->{'svn_userfile'} or die_cleanup("Cannot open filter file for reading [$O->{'svn_userfile'}]: $!");
        $svnuser = <$fh>;
        chomp($svnuser);
        close $fh;
    }
    my $svn_stat_cmd = "$O->{'svncmd'} st $O->{'basedir'}";
    foreach my $s (`$svn_stat_cmd`) {
        if ($s !~ /\.sql$|.pgr$/) {
            push @svn_ignored, $s;
            next;
        }
        if ($s =~ /^\?\s+(\S+)$/) {
            push @svn_add, $1;
        }
    }

    foreach my $i (@svn_ignored) {
        print "ignored: $i" if !$O->{'quiet'};
    }
    foreach my $a (@svn_add) {
        my $svn_add_cmd = "$O->{svncmd} add --quiet $a";
        print "$svn_add_cmd\n" if !$O->{'quiet'};
        system $svn_add_cmd;
    }

    #TODO add commands to cleanup empty folders
    if ($O->{'svndel'}) {
        my @files_to_delete = files_to_delete();
        if (scalar(@files_to_delete > 0)) {
            foreach my $d (@files_to_delete) {
                my $svn_del_cmd = "$O->{svncmd} del $d";
                print "$svn_del_cmd\n" if !$O->{'quiet'};
                system $svn_del_cmd;
            }
        } else {
            print "No files to delete from SVN\n" if !$O->{'quiet'};
        }
    }

    #Put commit message in external file to avoid issues with any special characters in it
    my $svn_commit_msg_file;
    if ($O->{'commitmsgfn'}) {
        $svn_commit_msg_file = $O->{'commitmsgfn'};
    } else {
        $svn_commit_msg_file = File::Temp->new( TEMPLATE => 'pg_extractor_XXXXXXX',
                                    SUFFIX => '.tmp',
                                    DIR => $O->{'basedir'});
        print $svn_commit_msg_file $O->{'commitmsg'}  if !$O->{'quiet'};
    }

    chdir $O->{'basedir'};
    my $svn_commit_cmd = "$O->{svncmd} $svnuser -F $svn_commit_msg_file commit";
    print "svn commit command: $svn_commit_cmd\n"  if !$O->{'quiet'}; ;
    system $svn_commit_cmd;

}

sub die_cleanup {
    my $message = shift @_;
    cleanup();
    die "$message\n";
}

sub cleanup {
   # Was used to cleanup temp files. Keeping for now in case other cleanup is needed
}

__END__

=pod

=head1 PGExtractor - pg_extractor.pl

=head1 DESCRIPTION
A script for doing advanced dump filtering and managing schema for PostgreSQL databases

=head1 SYNOPSIS

/path/to/pg_extractor.pl [options]

=head2 NOTES

 - Requires using a trusted user or a .pgpass file. No option to send password.
 - For all options that use an external file list, separate each item in the file by a newline.
    pg_extractor.pl will accept a list of objects output from a psql generated file using "\t \o filename"
 - If no schema name is given in an filter for tables, it will assume public schema (same as pg_dump). For other objects, not designating
    a schema will match across all schemas included in given filters. So, recommended to give full schema.object name for all objects.
 - If a special character is used in an object name, it will be replaced with a comma followed by its hexcode
    Ex: table|name becomes table,7cname.sql
 - VCS options (svn/git) assume a local repository has already been created. Recommend running pg_extractor once without any VCS options,
    committing manually, then adding any VCS options.
 - Comments/Descriptions on any object should be included in the export file. If you see any missing, please contact the author

=head1 OPTIONS

=head2 database connection

=over

=item --host (-h)

database server host or socket directory (Default: Result of running Sys::Hostname::hostname)

=item --port (-p)

database server port

=item --username (-U)

database user name

=item --pgpass

full path to location of .pgpass file

=item --dbname (-d)

database name to connect to. Also used as directory name under --hostname

=item --encoding

create the dump files in the specified character set encoding. By default, the dump is created in the database encoding.

=back

=head2 directories

=over

=item --basedir (ddlbase)

base directory for ddl export. ddlbase is from old version that was schema only. kept for compatibility. (Default: directory pg_extractor is run from '.' )

=item --hostname

hostname of the database server; used as directory name under --basedir

=item --pgdump

location of pg_dump executable (Default: searches $PATH )

=item --pgrestore

location of pg_restore executable (Default: searches $PATH )

=item --pgdumpall

location of pg_dumpall executable. only required if --getroles or --getall options are used (Default: searches $PATH )

=back

=head2 filters

=over

=item --gettables

export table ddl. Each file includes table's indexes, constraints, sequences, comments, rules and triggers

=item --getviews

export view ddl

=item --getfuncs

export function and/or aggregate ddl. Overloaded functions will all be in the same base filename

=item --gettypes

export custom types.

=item --getroles

include an export file containing all roles in the cluster.

=item --getall

gets all tables, views, functions, types and roles. Shortcut to having to set all --get* options. Does NOT include data

=item --getdata

include data in the output files. Note that format will be plaintext (-Fp) unless -Fc option is explicitly given.

=item --Fc

output in pg_dump custom format (useful with --getdata). Otherwise, default is always -Fp

=item --N

csv list of schemas to EXCLUDE

=item --N_file

path to a file listing schemas to EXCLUDE.

=item --n

csv list of schemas to INCLUDE

=item --n_file

path to a file listing schemas to INCLUDE.

=item --T

csv list of tables to EXCLUDE. Schema name may be required (same for all table options)

=item --T_file

path to file listing tables to EXCLUDE.

=item --t

csv list of tables to INCLUDE. Only these tables will be exported

=item --t_file

path to file listing tables to INCLUDE.

=item --V

csv list of views to EXCLUDE.

=item --V_file

path to file listing views to EXCLUDE.

=item --v

csv list of views to INCLUDE. Only these views will be exported

=item --v_file

path to file listing views to INCLUDE.

=item --P_file

path to file listing functions or aggregates to EXCLUDE.

=item --p_file

path to file listing functions or aggregates to INCLUDE.

=item --O

csv list of object owners to EXCLUDE. Objects owned by these owners will NOT be exported

=item --O_file

path to file listing object owners to EXCLUDE. Objects owned by these owners will NOT be exported

=item --o

csv list of object owners to INCLUDE. Only objects owned by these owners will be exported

=item --o_file

path to file listing object owners to INCLUDE. Only objects owned by these owners will be exported

=item --regex_incl_file

path to a file containing a regex pattern of objects to INCLUDE. Note this will match against all objects (tables, views, functions, etc)

=item --regex_excl_file

path to a file containing a regex pattern of objects to EXCLUDE. Note this will match against all objects (tables, views, functions, etc)

=item --no-owner

do not add commands to dump files to set ownership of objects to match the original database

=item --no-acl OR --no-privileges

prevent dumping of access privileges (grant/revoke commands)

=item --inserts

dump data as INSERT commands (rather than COPY). Only useful with --getdata option

=item --column-inserts OR --attribute-inserts

dump data as INSERT commands with explicit column names (INSERT INTO table (column, ...) VALUES ...). Only useful with --getdata option

=back

=head2 Version Control

=over

=item --git

perform git commit of basedir/hostname folder. This is a local commit only. See --gitpush for pushing to remote repositories

=item --gitpush

perform a local git commit of basedir/hostname folder as well as push to an already configured remote repository

=item --gitcmd

full path location of git command (Default: searches $PATH )

=item --gitdel

delete any files from the git repository that are no longer part of the desired export. WARNING: This WILL delete ALL .sql files in the destination folder(s) which don't match your desired output. --delete option is not required when this is set, since it will also delete files from disk if they were part of a previous export.

=item --svn

perform svn commit of basedir/hostname/dbname folder.

=item --svn_userfile

file containing the svn username and password if needed. Make sure the user running pg_extractor can read this file.
File should contain a single line in the format: --username svnuser --password svnpassword

=item --svncmd

full path location of svn command (Default: searches $PATH )

=item --svndel

delete any files from the svn repository that are no longer part of the desired export. WARNING: This WILL delete ALL .sql files in the destination folder(s) which don't match your desired output. --delete option is not required when this is set, since it will also delete files from disk if they were part of a previous export.

=item --commitmsg

Commit message to send to git or svn

=item --commitmsgfn

File containing the commit message to send to git or svn



=back

=head2 other

=over

=item --delete

Use when running again on the same destination directory as previous runs so that objects deleted from the
database or items that don't match your filters also have their old files deleted. WARNING: This WILL delete ALL .sql files in the destination folder(s) which don't match your desired output. Not required when using the --svndel option.

=item --sqldump

Also generate a pg_dump file. Will only contain schemas and tables designated by original options.
Note that other filtered items will NOT be filtered out of the dump file.

=item --quiet

Suppress all program output

=item --help (-?)

show this help page

=back

=head1 EXAMPLES

=over

=item Basic minimum usage. This will extract all tables, functions/aggregates, views, types & roles. It uses the directory that pg_extractor is run from as the base directory (objects will be found in ./hostname/mydb/) and will also produce a permanent copy of the pg_dump file that the objects were extracted from. It expects the locations of the postgres binaries to be in the $PATH.

perl pg_extractor.pl -U postgres --dbname=mydb --getall --sqldump

=item Extract only functions from the "keith" schema

perl pg_extractor.pl -U postgres --dbname=mydb --getfuncs --n=keith

=item Extract only specifically named functions in the given filename (newline separated list). Ensure the full function signature is given with only the variable types for arguments. When using include files, it's best to explicitely name the schemas they're in as well (it makes the temporary dump file that's created smaller).

perl pg_extractor.pl -U postgres --dbname=mydb --getfuncs -p_file=/home/postgres/func_incl --n=dblink

 func_incl file contains:
 dblink_exec(text, text)
 dblink_exec(text, text, boolean)
 dblink_exec(text)
 dblink_exec(text, boolean)

=item Extract only the tables listed in the given filename (newline separated list) along with the data in the pg_dump custom format.

perl pg_extractor.pl -U postgres --dbname=mydb --gettables -Fc --t_file=/home/postgres/tbl_incl --getdata

=item Example of excluding partitions that have the pattern tablename_pYYYY_MM or fairly similar. Binaries are also not in the $PATH and EXCLUDES several schemas. part_exclude file contains: _p_?(20|19)\d\d(_?\d+)*$ .

perl pg_extractor.pl -U postgres --dbname=mydb --pgdump=/opt/pgsql/bin/pg_dump --pgrestore=/opt/pgsql/bin/pg_restore --pgdumpall=/opt/pgsql/bin/pg_dumpall --getall --regex_excl_file=/home/postgres/part_exclude --N=schema1,schema2,schema3,schema4

=item Using svn (svn username & password must be set in script source). Also cleans up objects from svn that have been removed from the database.

perl pg_extractor.pl -U postgres --dbname=mydb --svn --svncmd=/opt/svn/bin/svn --commitmsg="Weekly svn commit of postgres schema" --svndel

=back

=head1 AUTHOR

    Keith Fiske
    OmniTI, Inc - http://www.omniti.com
    Download source from https://github.com/omniti-labs/pg_extractor

=head1 LICENSE AND COPYRIGHT

PGExtractor is released under the PostgreSQL License, a liberal Open Source license, similar to the BSD or MIT licenses.

Copyright (c) 2011 OmniTI, Inc.

Permission to use, copy, modify, and distribute this software and its documentation for any purpose, without fee, and without a written agreement is hereby granted, provided that the above copyright notice and this paragraph and the following two paragraphs appear in all copies.

IN NO EVENT SHALL THE AUTHOR BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF THE AUTHOR HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

THE AUTHOR SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND THE AUTHOR HAS NO OBLIGATIONS TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.

=cut
