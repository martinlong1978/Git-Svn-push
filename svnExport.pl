#!/usr/bin/perl

# Copyright 2011 Martin Long

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

# http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

use strict;
use File::Path;
use File::Basename;
use FileHandle;

# SYNC_BASE can be overridden by passing it as the first argument
my $SYNC_BASE="/export/home/javadev/gitsync";
my $GIT_ROOT;
my $SVN_ROOT;
my $COMMIT_MESG;

my $GIT_FETCH_REF;
my $GIT_BRANCHES_GLOB;

# These are loaded per-project
my @BRANCH_ORDER;
my $SVN_REPO_URL; # example: "https://example.com/project"
my $SVN_BRANCHES_GLOB; # default: "branches/*/trunk"
my $SVN_TRUNK_EXT; # default: "trunk"

# globmatch("abc*ghi", "abcdefghi") == "def"
sub globmatch {
	my ($glob, $text) = @_;
	$glob =~ s/\*/(.*)/;
	if ($text =~ m/$glob/)
	{
		return $1;
	}
	else
	{
		return undef;
	}
}

# globinsert("abc*ghi", "def") == "abcdefghi"
sub globinsert {
	my ($_, $text) = @_;
	s/\*/$text/;
	return $_;
}

sub ref2branch {
	my ($ref) = @_;
	return globmatch($GIT_BRANCHES_GLOB, $ref);
}

sub branch2ref {
	my ($branch) = @_;
	return globinsert($GIT_BRANCHES_GLOB, $branch);
}

# Get the branch url. Will be a different scheme for trunk
# /trunk or /branches/branch/trunk.
#
sub geturlforbranch
{
	my ($branch) = @_;
	if (substr $SVN_REPO_URL, -1, 1 == "/") {
		die("Don't put a / at the end of SVN_REPO_URL (" . $SVN_REPO_URL . ")");
	}

	if($branch eq ref2branch($GIT_FETCH_REF))
	{
		return "$SVN_REPO_URL/$SVN_TRUNK_EXT";
	}
	else
	{
		# $SVN_BRANCHES_GLOB has a * where the branch name should go.  This is
		# similar to the globbing style git-svn deals with these things.
		return "$SVN_REPO_URL/" . globinsert($SVN_BRANCHES_GLOB, $branch);
	}
}

# Create a new branch from parent at a specific GIT revision.
#
sub branchfromparent
{
	my ($project, $branch, $br_parent, $revision) = @_;

	my $svn_from = geturlforbranch($br_parent);
	my $svn_to = geturlforbranch($branch);

	print "Branching $branch from $br_parent at rev $revision\n";

	# Lookup the SVN revision at which to create the branch.
	my $svnrev = `cat $SVN_ROOT/$project.revcache |grep $revision |cut -d " " -f 1`;
	chomp($svnrev);

	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision") == 0 
		or die "Could not create tracking tag";

	#Do the branching 
	system("svn copy --parents  $svn_from\@$svnrev $svn_to -m \"Branch for $branch\"") == 0
		or die "Could not create branch";
}

# Create the first branch - the one for which no parent can be found.
#
sub createfirst
{
	my ($project, $branch, $revision) = @_;

	my $svn_url = geturlforbranch($branch);

	print("New project branch: $branch\n");

	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision") == 0
		or die "GIT Failure";

	#Checkout for initial commit
	system("git checkout $revision") == 0
		or die "GIT Failure";

	#Create trunk and checkout working copy
	system("svn mkdir --parents $svn_url -m \"Creating trunk\"") == 0
		or die("Could not connect to $svn_url");

	chdir("$SVN_ROOT")
		or die("Couldn't jump to svn temp store: $SVN_ROOT");
	system("svn co $svn_url $project") == 0
		or die("Could not connect to $svn_url");


	chdir("$SVN_ROOT/$project")
		or die("Couldn't jump to svn temp store: $SVN_ROOT/$project");

	# Initialise the first commit. GIT won't do this for us :(	
	syncsvnfiles($project, "$SVN_ROOT");

	system("svn commit -m \"Initial commit.\"") == 0
		or die("Commit failed.");
		
	chdir("$SVN_ROOT")
		or die("Couldn't jump to svn temp store: $SVN_ROOT");

	# temp dir is no longer needed - we'll commit the diffs from now
	system("rm -rf \"$SVN_ROOT/$project\"");
}

# Find the parent and branch point by looping back through the branch rev-list
# Until we find a rev that has already been committed to another branch. Branches
# are evaluated in specified order, followed by any unspecified, to ensure that 
# branch parenting is as desired.
#
sub initbranch
{
	my ($branch, $project) = @_;
	print("Looking for parent of: $branch\n");

	# Load the revision cache into a hash. We do this here locally
	# for each branch, as it is generally a rare operation. 
	open(REVCACHE, "$SVN_ROOT/$project.revcache");
	my %revcache = ();
	for my $cacheentry (<REVCACHE>)
	{
		chomp($cacheentry);
		my @entry = split(/ /, $cacheentry);
		$revcache{$entry[2]} = $entry[1];
	}
	close(REVCACHE);

	my $rev_last;

	open(REVS, "git rev-list --first-parent " . branch2ref($branch) . " |") or die "Broken";

	# Loop back through the rev-list. First parents only. We don't care about 
	# feature branches that are already merged. The merge commit will do - that's
	# all svn would give anyway.
	for my $revision (<REVS>)
	{
		chomp($revision);
		print("Looking for parent in rev: $revision\n");
		my $br_parent = $revcache{$revision};
		if($br_parent ne "")
		{
			# Found it... now BRANCH!
			branchfromparent($project, $branch, $br_parent, $revision);
			return;
		}
		$rev_last = $revision;
	}

	close(REVS);
	
	# No findy? Must be trunk then.
	createfirst($project, $branch, $rev_last);
}

# Called per-project to do all processing of that project.
#
sub processproject
{
	my ($project) = @_;
	print("Processing project: $project\n");
	
	$ENV{'GIT_DIR'} = "$GIT_ROOT/$project/.git";
	$ENV{'GIT_WORK_TREE'} = "$GIT_ROOT/$project";

	
	chdir("$GIT_ROOT/$project") or die ("Can't change to project directory: $project");

	# Update the GIT repo from it's origin (or specified remote)
	system("git fetch --all") == 0
		or die("GIT fetch failed.");

	# Fetch review notes
	system("git fetch origin +refs/notes/*:refs/notes/*") == 0
		or die("GIT fetch failed.");

	# Load this with the branches to process, ordered correctly.
	my @branches;

	print("Configured branches: @BRANCH_ORDER\n");

	# First, the branches specified. Trunk will be first.
	for my $branch (@BRANCH_ORDER)
	{
		push(@branches, "$branch");
	}

	# Then any that are left over
	open(REFS, "git for-each-ref --format=\"\%(refname)\" $GIT_BRANCHES_GLOB $GIT_FETCH_REF |grep -v HEAD|");
	
	for my $branch (<REFS>)
	{
		chomp($branch);
		$branch = ref2branch($branch);
		# Only add it if it wasn't in the specified list. (ie already added)
		if(!grep($branch eq "$_", @BRANCH_ORDER))
		{
			# Exclude personal feature branches
			if($branch !~ m/feature/)
			{
				print("Adding branch: $branch\n");
				push(@branches, $branch);
			}
		}
	}
	close(REFS);

	# Now process the branches
	for my $branch (@branches)
	{
		processbranch($project, $branch);
	}
}

# This is only done for the first commit, for which commit-diff cannot work.
#
sub syncsvnfiles
{
	my ($project, $svndir) = @_;

	# Copy all of the files to the SVN working directory
	
	
	system("(cd $GIT_ROOT/ ; tar cf - $project) | (cd $svndir ; tar xvf -)") == 0
		or die("Failed to sync dir: $GIT_ROOT/$project to: $svndir");

	# Remove the .git stuff... we really don't want to commit that.
	system("rm -rf $svndir/$project/.git") == 0
		or die("Could not remove .git dir from svn working copy");

	# Add anything that isn't already (should be everything) 
	open(TOADD, "svn status |grep \?|");
	for my $path (<TOADD>)
	{
		chomp($path);
		if ("$path" ne "?" )
		{
			$path =~ s/\?\s+(.*)/\1/;
			system("svn add \"$path\"") == 0
				or die("Could not add files to svn index");
		}
	}
	close(TOADD);
}

# Commit the branch commits across to SVN
#
sub processbranch
{
	my ($project, $branch) = @_;
	print("Processing $branch of $project\n");

	my $ref = branch2ref($branch);

	chdir("$GIT_ROOT/$project") or die("Can't change to project directory: $project");

	# If the tracking tag doesn't exist, then we need to initialise the branch 
	# in svn.
	my $tag = `git tag -l svnbranch/$branch | wc -l`;
	chomp($tag);
	if($tag < 1)
	{
		initbranch($branch, $project);
	}

	chdir("$GIT_ROOT/$project") or die("Can't change to project directory: $project");

	# Find the last rev synced, from the tracking tag we created.
	my $lastrev = `git show-ref -s --dereference svnbranch/$branch`;
	chomp($lastrev);
	print("Last revision synced: $lastrev\n");

	# Loop through all the revs between then and now (again, first parent chain only).
	open(BRANCHREVS, "git rev-list --first-parent --reverse ${lastrev}..${ref}|");
	for my $revision (<BRANCHREVS>)
	{
		chomp($revision);
		print("Preparing to write revision $revision\n");
		chdir("$GIT_ROOT/$project");

		# Write the commit message to a file
		system("git log -1 --show-notes=review --format=format:\"\%B\%nCommitter: \%an - Date: \%aD\%n\%N\" $revision |grep -v git-svn-id >$COMMIT_MESG/${revision}") == 0
			or die("Could not get log message");

		my $svn_url = geturlforbranch($branch);

		# Commit using commit-diff - this avoids the need to mess around with 
		# working copies and files
		open(COMMIT, "git svn commit-diff -r HEAD svnbranch/$branch $revision  $svn_url -F $COMMIT_MESG/$revision 2>&1 |");
		
		# Make sure it commited. Cache the rev number to spot branch 
		# points later, and also, update the tracking tag in GIT. 
		while(<COMMIT>)
		{
			chomp;
			print("$_\n");
			if($_ =~ m/^Committed/)
			{
				#Committed rxxxx
				$_ =~ s/Committed r([0-9]*)/\1/;
				open(REVCACHE, ">>$SVN_ROOT/$project.revcache");
				print(REVCACHE "$_ $branch $revision\n");
				close(REVCACHE);

				chdir "$GIT_ROOT/$project";
				system("git tag -f svnbranch/$branch $revision") == 0
					or die("Could not create GIT tracking tag");
			}elsif($_ =~ m/^No.changes/)
			{
				# If no commit was made, still update the tag. No need to 
				# add to rev cache (we have no rev anyway). Walker will just keep
				# walking and branch from a revision that has a change.
				chdir "$GIT_ROOT/$project";
				system("git tag -f svnbranch/$branch $revision") == 0
					or die("Could not create GIT tracking tag");
			} 
		}
		close(COMMIT);
		
		#Clean up the commit message file.
		unlink("$COMMIT_MESG/$revision");
	}
	close(BRANCHREVS);
}

# Read in the config file for the repo. 
#
sub parse_config_file 
{
    my ($File) = @_;
    my ($config_line, $Name, $Value, %Config);

    print("Loading $File\n");

    open(CONFIG, "$File")
	    or die("ERROR: Config file not found : $File");

    # Defaults:
    $Config{"SVN_BRANCHES"} = "branches/*/trunk:refs/remotes/origin/*";

    while (<CONFIG>) 
    {
        $config_line = $_;
        chomp($config_line);
        $config_line =~ s/^\s*//;
        $config_line =~ s/\s*$//;
        if (($config_line !~ /^#/) && ($config_line ne ""))
        {
            ($Name, $Value) = split (/=/, $config_line);
            $Config{$Name} = $Value;
        }
    }

    close(CONFIG);

	if (!defined($Config{"SVN_FETCH"})) {
		if (defined($Config{"BRANCH_ORDER"})) {
			# Backwards compatibility
			my $trunk=${split(",", $Config{"BRANCH_ORDER"})}[0];
			$Config{"SVN_FETCH"} = "trunk:refs/remotes/origin/$trunk";
		}
		else {
			$Config{"SVN_FETCH"} = "trunk:refs/remotes/origin/master";
		}
	}
	return %Config;
}

# Main sub. Do the import!
#
sub doimport
{
	if (scalar(@ARGV) != 0) {
		$SYNC_BASE = $ARGV[0];
	}
	$GIT_ROOT="$SYNC_BASE/GIT";
	$SVN_ROOT="$SYNC_BASE/workingdata";
	$COMMIT_MESG="$SVN_ROOT/messages";

	mkpath $COMMIT_MESG;

	# Loop through any project with a .config file
	for my $projectconfig (glob "$GIT_ROOT/*.config")
	{
		my $project = $projectconfig;
		my %config;
		$project =~ s/(.*)\.config/\1/;

		# Lock the project, one at a time please
		open(LCK, ">${project}.lock");
		flock(LCK, 2) or die "Cannot lock file";
		print(LCK "Locked");
		
		%config = parse_config_file($projectconfig);

		($SVN_TRUNK_EXT, $GIT_FETCH_REF) = split(":", $config{"SVN_FETCH"});
		($SVN_BRANCHES_GLOB, $GIT_BRANCHES_GLOB) = split(":", $config{"SVN_BRANCHES"});

		$SVN_REPO_URL = $config{"SVN_URL"};
		my $BRANCHES = $config{"BRANCH_ORDER"};
		@BRANCH_ORDER = ();
		@BRANCH_ORDER = split(",", $BRANCHES);

		if (! defined globmatch($GIT_BRANCHES_GLOB, $GIT_FETCH_REF)) {
			die "Not supported: $GIT_FETCH_REF must match $GIT_BRANCHES_GLOB";
		}

		processproject(basename($project));
		
		close(LCK);
		unlink ("${project}.lock");
	}
}

doimport;

