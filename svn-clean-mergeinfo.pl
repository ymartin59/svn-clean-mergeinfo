#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp;
use Pod::Usage;
use Getopt::Long; Getopt::Long::Configure("bundling", "nodebug"); 

##  Constants
use constant FALSE => 0;
use constant TRUE => 1;
my $ROOTNODE = ".";

## Hash to store option values from command line parsing
my %options =
    ( "verbose" => FALSE,
      "debug" => FALSE,
      "statusonly" => FALSE,
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
    
    # Parsing state variable
    my $lastNode = undef;
    my $lastNodeMerges = {};

    print "Parsing svn:mergeinfo...\n" if $options{"verbose"};

    open(MERGEINFO, "svn propget svn:mergeinfo --depth=infinity |")
        or die "Cannot run svn propget $!";

    while(my $line = <MERGEINFO>) {
        if ($line =~ /^\S+ - /) {
            # Collect previous node
            if (defined($lastNode)) {
                $mergeinfonodes{$lastNode} = $lastNodeMerges;
            }
            
            my ($node, $branch, $revlist) = ($line =~ /^(\S+) - (.*):(.*)$/);
            $lastNode = $node;
            $lastNodeMerges = {};
            $lastNodeMerges->{$branch} = parseRevisionList($revlist);
            print "Node $node : from $branch revisions $revlist\n" if $options{"debug"};
            
        } elsif ($line =~ /:/) {
            my ($branch, $revlist) = ($line =~ /(.*):(.*)$/);
            $lastNodeMerges->{$branch} = parseRevisionList($revlist);
            print "             from $branch revisions $revlist\n" if $options{"debug"};
        } else {
            print "Unexpected line from propget svn:mergeinfo $line\n";
        }
    }
    if (defined($lastNode)) {
        $mergeinfonodes{$lastNode} = $lastNodeMerges;
    }
    close(MERGEINFO);

    print "Collected " . keys(%mergeinfonodes). " nodes.\n" if $options{"verbose"};

    return %mergeinfonodes;
}

# Check file modified by a revision are all included in branchPath
sub checkRevisionPath($$) {
    my $branchPath = shift;
    my $revision = shift;

    # Remove ending /
    $branchPath = substr($branchPath, 1, length($branchPath) - 1);

    print "Parse diff for revision $revision\n" if $options{"debug"};

    open(DIFF, "svn diff -c $revision ^/ |")
        or die "Cannot run svn diff $!";

    while(my $line = <DIFF>) {
        if ($line =~ /^Index: /) {
            if ($line !~ /^Index: $branchPath/) {
                print "Revision $revision contains file out of $branchPath : $line" if $options{"verbose"};
                return FALSE;
            }
        }
    }
    close(DIFF);
    return TRUE;
}

# Apply checks and clean svn:mergeinfo from revisions
# already included in root directory.
sub consolidate($) {
    my $mergeinfonodes = shift;

    my $rootMerges = $mergeinfonodes->{$ROOTNODE};
    if (!exists($mergeinfonodes->{$ROOTNODE})) {
        $rootMerges = {};
    }

    foreach my $node (sort(keys %{$mergeinfonodes})) {
        next if ($node =~ /^.$/);
        my $nodeMerges = $mergeinfonodes->{$node};
        foreach my $branch (sort(keys %$nodeMerges)) {

            my $noPathCheck = FALSE;
            if ($branch !~ /$node$/) {
                print "Unexpected $branch in mergeinfo on node $node\n";
                $noPathCheck = TRUE;
                next;
            }
            # Extract root branch without trailing /
            my $rootBranch = substr($branch, 0, length($branch) - length($node) - 1);
            print "\nNode $node, consolidate $branch on $rootBranch\n";

            my @revList = @{$nodeMerges->{$branch}};
            next if (!exists($nodeMerges->{$branch}) || (@revList < 1));

            my @remainingRevList = ();
            foreach my $rev (@revList) {
                # Test revision if already included in root svn:mergeinfo
                if (exists($rootMerges->{$rootBranch})
                    && grep {$_ eq $rev} (@{$rootMerges->{$rootBranch}})) {
                    next;
                }
                
                # Test if revision is limited to node path
                if (!$noPathCheck
                    && $rev !~ /\*$/
                    && checkRevisionPath($rootBranch, $rev)) {
                    print "  Add $rev from $rootBranch to root node\n" if $options{"verbose"};

                    if (!exists($rootMerges->{$rootBranch})) {
                        # Only add branch on root node when required
                        $rootMerges->{$rootBranch} = [];
                    }
                    push(@{$rootMerges->{$rootBranch}}, $rev);
                    next;
                }
                push(@remainingRevList, $rev);
            }

            if (!@remainingRevList) {
                print "  Branch $branch empty\n" if $options{"verbose"};
                delete($nodeMerges->{$branch});
                next;
            }

            $nodeMerges->{$branch} = \@remainingRevList;
            print "  Branch $branch : " . @{$nodeMerges->{$branch}} . " revisions\n";
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
        my $nodeMerges = $mergeinfonodes{$node};


        if (!(keys %$nodeMerges)) {
            print "Delete svn:mergeinfo on $node\n" if $options{"debug"};
            `svn propdel svn:mergeinfo $node`;
            next;
        }

        print "Write svn:mergeinfo property for node $node\n";
        my $mergeinfo = File::Temp->new();
        $mergeinfo->unlink_on_destroy(1);

        foreach my $branch (sort(keys %$nodeMerges)) {
            print "  Branch $branch : " . @{$nodeMerges->{$branch}} . " revision\n";
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
}


# command line argument processing
GetOptions(
    "help|h" => sub { pod2usage( { -verbose => 1, -exitval => -2 } ) },
    "man|m" => sub { pod2usage( { -verbose => 2, -exitval => -2, -noperldoc => 1 } ) },
    "verbose" => \$options{"verbose"},
    "debug" => sub { $options{"debug"} = TRUE; $options{"verbose"} = TRUE },
    "status|s" => \$options{"statusonly"},
    "nowrite|n" => \$options{"nowrite"},
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

=item C<svn-clean-mergeinfo.pl [--debug] [--verbose] [--nowrite]>

consolidates C<svn:mergeinfo> properties in a Subversion working copy to the root
node. If the option C<--nowrite> is enabled, consolidated properties are not
written to the working but only reported as a summary.


=item C<svn-clean-mergeinfo.pl --status>

prints a summary of C<svn:mergeinfo> properties content as numbers of merged
revisions for each branch.

=back

=head1 OPERATION

First it parses C<svn:mergeinfo> and scans for branch/revisions on non-root
folders.

If a revision is already included at the root node level, it is discarded from
sub-folders.

If a revision only modifies files included in the scan sub-folder, it is discarded from the sub-folder and appended at root level.

In some cases, a branch name is non consistent with the current node name, so
it is left as-is for a manual check if the revision content was partially
merged or not.

After the operation and without C<--nowrite> option, the working copy
C<svn:mergeinfo> are modified so that you can inspect the result before a
commit. If the svn:mergeinfo property is empty, it is planned for removal.

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

=item B<--verbose>

prints progress messages to the standard output.

=item B<--debug>

prints debug messages to the standard output.

=item B<--nowrite>, B<-n>

disables C<svn propset> operations of consolidated C<svn:mergeinfo> properties.

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
