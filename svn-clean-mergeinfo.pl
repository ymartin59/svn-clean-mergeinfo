#!/usr/bin/env perl

## svn-clean-mergeinfo.pl is a command line tool to consolidate Subversion
## svn:mergeinfo properties on a working copy.

## Copyright (C) 2012,2014  Yves Martin  ( ymartin1040 _at_ gmail _dot_ com )

# Here are license details
sub license() {
    print <<EOF;
  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License version 3
  as published by the Free Software Foundation.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You can get a copy of the GNU General Public License
  at http://www.gnu.org/licenses/gpl.html
EOF
}

sub banner() {
    print <<EOF;
 Copyright (C) 2012,2014  Yves Martin
 This program comes with ABSOLUTELY NO WARRANTY.
 This is free software, and you are welcome to redistribute it
 under certain conditions. See LICENSE file for details.

EOF
}

use strict;
use warnings;
use File::Temp;
use Pod::Usage;
use Getopt::Long; Getopt::Long::Configure("bundling", "nodebug"); 

##  Constants
use constant FALSE => 0;
use constant TRUE => 1;
use constant REVCOUNT => "REVCOUNT";
my $ROOTNODE = ".";

## Hash to store option values from command line parsing
my %options =
    ( "verbose" => FALSE,
      "debug" => FALSE,
      "statusonly" => FALSE,
      "checkpoint" => 500,
      "prunebranches" => FALSE,
      "nowrite" => FALSE,
    );

# Split revision list structure into a full numeric list
# Return a reference to the result list
sub parseRevisionList($) {
    my $revs = $_[0];
    my @result = ();
    foreach my $aset (split(/,/,$revs)) {
        if ($aset =~ /^\d+-\d+$/) {
            my ($from, $to) = ($aset =~ /^(\d+)-(\d+)$/);
            while ($from <= $to) {
                push(@result, $from++);
            }
        } elsif ($aset =~ /^\d+\*?$/) {
            if ($aset =~ /\*$/) {
                print "Warning: revision $aset\n" if $options{"verbose"};
            }
            push(@result, $aset);
        } else {
            print "Unexpected revision '$aset' in mergeinfo $revs\n";
        }
    }
    return \@result;
}

# Dump mergeinfo nodes information
#  { Node -> \{ Branch -> \( Revision List ) } }
sub dumpMergeInfoNodes($) {
    my %mergeinfonodes = %{$_[0]};
    foreach my $node (sort(keys %mergeinfonodes)) {
        next if ($node =~ /^REVCOUNT$/);  # skip technical node revisions counter
        print "Node $node\n";
        my $nodeMerges = $mergeinfonodes{$node};
        foreach my $branch (sort(keys %$nodeMerges)) {
            print "  Branch $branch : " . @{$nodeMerges->{$branch}} . " revisions\n";
            #print "  Branch $branch : " . join(" ", @{$nodeMerges->{$branch}}) . "\n";
            #print "  Branch $branch : " . buildRevisionList(@{$nodeMerges->{$branch}}) . "\n";
        }
    }
}

# Parse svn:mergeinfo properties and feed a structure
#  { Node -> \{ Branch -> \( Revision List ) } }
sub parseMergeInfo() {
    my %mergeinfonodes = ();

    # Ugly technical node to track revisions count
    $mergeinfonodes{REVCOUNT} = 0;
    
    # Parsing state variable
    my $lastNode = undef;
    my $lastNodeMerges = {};

    print "Parsing svn:mergeinfo...\n" if $options{"verbose"};

    open(MERGEINFO, "svn propget svn:mergeinfo --depth=infinity " . join(" ", @ARGV) . " |")
        or die "Cannot run svn propget $!";

    while(my $line = <MERGEINFO>) {
        if ($line =~ /^\S+ - /) {
            # Collect previous node
            if (defined($lastNode)) {
                $mergeinfonodes{$lastNode} = $lastNodeMerges;
            }
            
            my ($node, $branch, $revlist) = ($line =~ /^(\S+) - (.*):(.*)$/);
            # Convert path separator on windows platform
            $node =~ s!\\!/!g;
            $lastNode = $node;
            $lastNodeMerges = {};
            $lastNodeMerges->{$branch} = parseRevisionList($revlist);
            $mergeinfonodes{REVCOUNT} += scalar(@{$lastNodeMerges->{$branch}});
            print "Node $node : from $branch revisions $revlist\n" if $options{"debug"};
            
        } elsif ($line =~ /:/) {
            my ($branch, $revlist) = ($line =~ /(.*):(.*)$/);
            $lastNodeMerges->{$branch} = parseRevisionList($revlist);
            $mergeinfonodes{REVCOUNT} += scalar(@{$lastNodeMerges->{$branch}});
            print "             from $branch revisions $revlist\n" if $options{"debug"};
        } else {
            print "! Unexpected line from propget svn:mergeinfo $line\n";
        }
    }
    if (defined($lastNode)) {
        $mergeinfonodes{$lastNode} = $lastNodeMerges;
    }
    close(MERGEINFO);

    print "Collected " . keys(%mergeinfonodes). " nodes.\n" if $options{"verbose"};

    return %mergeinfonodes;
}

# Get working copy Repository Root
sub getRepositoryRoot() {
    my $svnroot = undef;
    open(INFO, "svn info |")
        or die "Cannot run svn info $!";
    while(my $output = <INFO>) {
        if ($output =~ /Repository Root/) {
            ($svnroot) = ($output =~ /Repository Root: (.*)/);
            last;
        }
    }
    close(INFO);
    if (!defined($svnroot)) {
        die "Fail to get working copy Repository Root";
    }
    return $svnroot;
}

# Check file modified by a revision are all included in branchPath
sub checkRevisionPath($$$) {
    my $svnroot = shift;
    my $branchPath = shift;
    my $revision = shift;
    my $result = TRUE;

    # Remove ending /
    $branchPath = substr($branchPath, 1, length($branchPath) - 1);

    print "Parse diff for revision $revision\n" if $options{"debug"};

    open(DIFF, "svn diff -c $revision --summarize ^/ |")
        or die "Cannot run svn diff $!";

    while(my $line = <DIFF>) {
        if ($line =~ /^[AMDR]/) {
            if ($line !~ /^[AMDR]\s+$svnroot\/$branchPath/) {
                print "Revision $revision contains file out of $branchPath : $line" if $options{"verbose"};
                $result = FALSE;
                last;
            }
        }
    }
    close(DIFF);
    return $result;
}

# Test if a repository path still exists in HEAD, typically a branch
sub existsRepositoryPath($$) {
    my $svnroot = shift;
    my $branchPath = shift;
    my $result = TRUE;

    print "Test repository path $branchPath\n" if $options{"debug"};

    open(SVNLS, "svn ls $svnroot\/$branchPath 2>&1 |")
        or die "Cannot run svn ls $!";

    while (my $line = <SVNLS>) {
        print "svn ls $branchPath content:  $line\n" if $options{"debug"};
        if ($line =~ /^svn: E200009: Could not list all targets/) {
            $result = FALSE;
        }
    }
    close(SVNLS);
    return $result;
}

# Apply checks and clean svn:mergeinfo from revisions
# already included in root directory.
sub consolidate($) {
    my $mergeinfonodes = shift;
    my $progressCounter = 0;

    my $rootMerges = $mergeinfonodes->{$ROOTNODE};
    if (!exists($mergeinfonodes->{$ROOTNODE})) {
        $rootMerges = {};
    }

    my $svnRoot = getRepositoryRoot();

    foreach my $node (sort(keys %{$mergeinfonodes})) {
        next if ($node =~ /^REVCOUNT$/);  # skip technical node revisions counter
        next if ($node =~ /^.$/);
        my $nodeMerges = $mergeinfonodes->{$node};
        foreach my $branch (sort(keys %$nodeMerges)) {

            my ($noPathCheck, $warning, $rootBranch) = (FALSE, "", undef);

            if ($branch =~ /$node$/) {
                $rootBranch = substr($branch, 0, length($branch) - length($node) - 1);
            }
            elsif ($branch =~ /^[\\\/](?:trunk|(?:(?:tags|branches)[\\\/][^\\\/]+))[\\\/]/ ) {
                ($rootBranch) = $branch =~ /^([\\\/](?:trunk|(?:(?:tags|branches)[\\\/][^\\\/]+)))[\\\/]/;
                $warning = "  ! Unexpected $branch in mergeinfo on node $node - Use root branch: $rootBranch\n";
            }
            else {
                $warning = "  ! Unexpected $branch in mergeinfo on node $node\n";
                $noPathCheck = TRUE;
                next;
            }

            print "\nNode $node, consolidate $branch on $rootBranch\n" . $warning;

            if ($options{"prunebranches"}) {
                if (!existsRepositoryPath($svnRoot, $branch)) {
                    delete($nodeMerges->{$branch});
                    print "  ! Remove reference to no longer available branch $branch in repository HEAD $svnRoot\n";
                    next;
                }
            }

            my @revList = @{$nodeMerges->{$branch}};
            next if (!exists($nodeMerges->{$branch}) || (@revList < 1));

            my @remainingRevList = ();
            while (scalar(@revList) > 0) {

                $progressCounter++;
                if ($options{"checkpoint"} != 0
                    && ($progressCounter % $options{"checkpoint"}) == 0) {

                    if (!$options{"nowrite"}) {
                        # Intermediate write back to working copy
                        $nodeMerges->{$branch} = \( @remainingRevList, @revList );
                        writeProperties($mergeinfonodes);
                    }

                    printf("... %d revisions processed over %d (%.1f)%%\n\n",
                           $progressCounter,
                           $mergeinfonodes->{REVCOUNT},
                           100*$progressCounter/$mergeinfonodes->{REVCOUNT}
                        );
                }

                my $rev = shift(@revList);

                # Test revision if already included in root svn:mergeinfo
                if (exists($rootMerges->{$rootBranch})
                    && grep {$_ eq $rev} (@{$rootMerges->{$rootBranch}})) {
                    next;
                }
                
                # Test if revision is limited to node path
                if (!$noPathCheck
                    && $rev !~ /\*$/
                    && checkRevisionPath($svnRoot, $rootBranch, $rev)) {
                    print "  Add $rev from $rootBranch to root node\n" if $options{"verbose"};

                    if (!exists($rootMerges->{$rootBranch})) {
                        # Only add branch on root node when required
                        $rootMerges->{$rootBranch} = [];
                    }
                    push(@{$rootMerges->{$rootBranch}}, $rev);
                }
                else {
                    push(@remainingRevList, $rev);
                }
            }

            if (!@remainingRevList) {
                print "  Branch $branch empty\n" if $options{"verbose"};
                delete($nodeMerges->{$branch});
            } else {
                $nodeMerges->{$branch} = \@remainingRevList;
                print "  Branch $branch : " . scalar(@{$nodeMerges->{$branch}}) . " revisions\n";
            }
        }
    }

    if (keys(%{$rootMerges}) > 0) {
        # Only create root node when required
        $mergeinfonodes->{$ROOTNODE} = $rootMerges;
    }
}

sub writeProperties($) {
    my %mergeinfonodes = %{$_[0]};
    foreach my $node (sort(keys %mergeinfonodes)) {
        next if ($node =~ /^REVCOUNT$/);  # skip technical node revisions counter
        my $nodeMerges = $mergeinfonodes{$node};


        if (!(keys %$nodeMerges)) {
            print "Delete svn:mergeinfo on $node\n" if $options{"debug"};
            `svn propdel svn:mergeinfo $node`;
            next;
        }

        print "Write svn:mergeinfo property for node $node\n" if $options{"verbose"};
        my $mergeinfo = File::Temp->new();
        $mergeinfo->unlink_on_destroy(1);

        foreach my $branch (sort(keys %$nodeMerges)) {
            print "  Branch $branch : " . @{$nodeMerges->{$branch}} . " revision\n" if $options{"verbose"};
            # TODO improve with revision list compaction. No need, svn does it well
            print $mergeinfo $branch . ":" .
                join(",", @{$nodeMerges->{$branch}}) . "\n";
            # TODO basic sort fails with non-inheritable merges
            # join(",", sort {$a <=> $b} @{$nodeMerges->{$branch}}) . "\n";
        }
        $mergeinfo->close();
        my $filename = $mergeinfo->filename();
        print "Set svn:mergeinfo on node $node\n" if $options{"debug"};
        `svn propset svn:mergeinfo -F $filename $node`;
    }
    print "... " . scalar(keys %mergeinfonodes) . " svn:mergeinfo properties written to working copy\n";
}


# command line argument processing
GetOptions(
    "help|h" => sub { pod2usage( { -verbose => 1, -exitval => -2 } ) },
    "man|m" => sub { pod2usage( { -verbose => 2, -exitval => -2, -noperldoc => 1 } ) },
    "warranty" => sub { banner(); license(); exit(0); },
    "verbose" => \$options{"verbose"},
    "debug" => sub { $options{"debug"} = TRUE; $options{"verbose"} = TRUE },
    "status|s" => \$options{"statusonly"},
    "nowrite|n" => \$options{"nowrite"},
    "checkpoint|c=i" => \$options{"checkpoint"},
    "prunebranches|p" => \$options{"prunebranches"},
    )
    or pod2usage({ -verbose => 0, -exitval => -1 });

# Parse svn:mergeinfo returned for current working directory
my %infonodes = parseMergeInfo();

if ($options{"statusonly"}) {
    # Display svn:mergeinfo summary
    dumpMergeInfoNodes(\%infonodes);

} else {
    consolidate(\%infonodes);
    if (!$options{"nowrite"}) {
        writeProperties(\%infonodes);
    }
}

exit(0);

__END__

=pod

=head1 NAME

svn-clean-mergeinfo.pl

=head1 DESCRIPTION

Command line tool to consolidate C<svn:mergeinfo> properties to the root branch
node (C</trunk/> or C</branches/X.Y/>) and clean safely properties set on
sub-folders in a working copy tree.

=head1 SYNOPSIS

=over

=item C<svn-clean-mergeinfo.pl [--debug] [--verbose] [--nowrite] [path ...]>

consolidates C<svn:mergeinfo> properties in a Subversion working copy to the root
node. 

If the option C<--nowrite> is enabled, consolidated properties are not written
to the working copy but only reported as a summary.  If one or more path are
given as parameters, only consolidate this subset.

When the option C<--nowrite> is not set, C<svn:mergeinfo> properties are
persist in the current working copy every 500 checked revisions. This threshold
can be tuned with C<--checkpoint> option. A value of 0 means no intermediate
write will occur.

=item C<svn-clean-mergeinfo.pl --status [path ...]>

prints a summary of C<svn:mergeinfo> properties content as numbers of merged
revisions for each branch. If one or more path are given as parameters, reports
only information for this subset.

=back

=head1 OPERATION

This script must be invoked from a Subversion working copy directory, usually a
checkout of /trunk or of a branch.

First it parses C<svn:mergeinfo> and scans for branch/revisions on non-root
folders, eventually limited to paths given as arguments.

If a revision is already included at the root node level, it is discarded from
sub-folders.

If a revision only modifies files included in the scan sub-folder, it is
discarded from the sub-folder and appended at root level.

In some cases, a branch name is non consistent with the current node name, so
it is left as-is for a manual check if the revision content was partially
merged or not.

Without C<--nowrite> option, every 500 revisions (defined by checkpoint) and
after operation is completed, the working copy C<svn:mergeinfo> are modified so
that you can inspect the result before a commit. If the C<svn:mergeinfo>
property is empty, it is planned for removal.

In addition, the C<--prunebranches> option discards non-live branches from
C<svn:mergeinfo> properties to keep them compact after long history.

This script does not trigger a Subversion commit to the repository. That
operation is under your responsability after manual checks and validations.

It finally reports a summary of C<svn:mergeinfo> properties content as numbers
of merged revisions for each branch.




=head1 OPTIONS

=over

=item B<-h>, B<--help>

prints a brief help message and exit status is -2.

=item B<-m>, B<--man>

prints the manual page and exit status is -2.

=item B<--warranty>

prints usual "no warranty" message and license information.

=item B<--verbose>

prints progress messages to the standard output.

=item B<--debug>

prints debug messages to the standard output.

=item B<--prunebranches>, B<-p>

discards no longer live branches from C<svn:mergeinfo>. A test for paths on
repository HEAD is done.

=item B<--nowrite>, B<-n>

disables C<svn propset> operations of consolidated C<svn:mergeinfo> properties.

=item B<--checkpoint>, B<-c> afterRevisions

change write threshold which defaults to 500 analyzed revisions. 0 means the
script no longer partially update working copy as checkpoint.

=item B<--status>, B<-s>

only reports a summary of the current working copy C<svn:mergeinfo> properties.

=back

=head1 BUGS AND KNOWN LIMITATIONS

=over

=item *

Does not support any file name in working copy containing " - ".

=item *

Does not support non-inheritable merged revision, marked with a star.

=back

=head1 TODO

=over

=item *

Test with non-standard repository structure.

=item *

Prompt for removal of a non-existing origin branch path.

=back

=head1 COPYRIGHT

Copyright (C) 2012  Yves Martin
This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions

=cut
