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
use File::Copy::Recursive;

my $SYNC_BASE="/home/martin/gittest";
my $GIT_ROOT="$SYNC_BASE/GIT";
my $SVN_ROOT="$SYNC_BASE/workingdata";
my $COMMIT_MESG="$SVN_ROOT/messages";
my $REMOTE="origin";

# These are loaded per-project
my @BRANCH_ORDER;
my $SVN_BASE_URL;
my $TRUNK;

sub geturlforbranch
{
	my ($branch) = @_;

	if($branch eq $TRUNK)
	{
		return "$SVN_BASE_URL/trunk";
	}
	else
	{
		return "$SVN_BASE_URL/branches/$branch/trunk";
	}
}

sub branchfromparent
{
	my ($project, $branch, $br_parent, $revision) = @_;

	my $svn_from = geturlforbranch($br_parent);
	my $svn_to = geturlforbranch($branch);

	print "Branching $branch from $br_parent at rev $revision\n";

	my $svnrev = `cat $SVN_ROOT/$project.revcache |grep $revision |cut -d " " -f 1`;
	chomp($svnrev);

	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision") == 0 
		or die "Could not create tracking tag";

	#Branch 
	system("svn copy --parents  $svn_from\@$svnrev $svn_to -m \"Branch for $branch\"") == 0
		or die "Could not create branch";
}

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

	#Create branch and checkout working copy
	system("svn mkdir --parents $svn_url -m \"Creating trunk\"") == 0
		or die("Could not connect to $svn_url");
	mkpath("$SVN_ROOT/$project/temp")
		or die("Couldn't make svn temp store: $SVN_ROOT/$project/temp");
	chdir("$SVN_ROOT/$project/temp")
		or die("Couldn't jump to svn temp store: $SVN_ROOT/$project/temp");
	system("svn co $svn_url ../temp") == 0
		or die("Could not connect to $svn_url");

	# Initialise the first commit. GIT won't do this for us :(	
	syncsvnfiles($project, "$SVN_ROOT/$project/temp");

	system("svn commit -m \"Initial commit.\"") == 0
		or die("Commit failed.");

	# temp dir is no longer needed
	system("rm -rf \"$SVN_ROOT/$project/temp\"");
}

sub findparent
{
	my ($branch, $project) = @_;
	print("Looking for parent of: $branch\n");

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

	open(REVS, "git rev-list --first-parent remotes/$REMOTE/$branch |") or die "Broken";

	for my $revision (<REVS>)
	{
		chomp($revision);
		print("Looking for parent in rev: $revision\n");
		my $br_parent = $revcache{$revision};
		if($br_parent ne "")
		{
			branchfromparent($project, $branch, $br_parent, $revision);
			return;
		}
		$rev_last = $revision;
	}

	close(REVS);

	createfirst($project, $branch, $rev_last);
}

sub processproject
{
	my ($project) = @_;
	print("Processing project: $project\n");

	chdir("$GIT_ROOT/$project" or die "Can't change to project directory: $project");

	system("git fetch --all") == 0
		or die("GIT fetch failed.");

	my @branches;

	for my $branch (@BRANCH_ORDER)
	{
		push(@branches, "$branch");
	}

	open(REFS, "git for-each-ref --format=\"\%(refname:short)\" refs/remotes/$REMOTE |grep -v HEAD|");
	for my $branch (<REFS>)
	{
		chomp($branch);
		$branch =~ s/$REMOTE\/(.*)/\1/;
		if(!grep($branch eq "$_", @BRANCH_ORDER))
		{
			push(@branches, $branch);
		}
	}
	close(REFS);

	for my $branch (@branches)
	{
		processbranch($project, $branch);
	}
}

sub syncsvnfiles
{
	my ($project, $svndir) = @_;

	system("cp -RT $GIT_ROOT/$project $svndir") == 0
		or die("Failed to sync dir: $GIT_ROOT/$project to: $svndir");

	system("rm -rf $svndir/.git") == 0
		or die("Could not remove .git dir from svn working copy");

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

sub processbranch
{
	my ($project, $branch) = @_;
	print("Processing $branch of $project\n");

	chdir("$GIT_ROOT/$project" or die "Can't change to project directory: $project");

	my $tag = `git tag -l svnbranch/$branch | wc -l`;
	chomp($tag);
	if($tag < 1)
	{
		findparent($branch, $project);
	}

	chdir("$GIT_ROOT/$project" or die "Can't change to project directory: $project");

	my $lastrev = `git show-ref -s --dereference svnbranch/$branch`;
	chomp($lastrev);

	print("Last revision synced: $lastrev\n");

	my $svndir = "$SVN_ROOT/$project/$branch";

	mkpath $svndir;

	open(BRANCHREVS, "git rev-list --first-parent --reverse ${lastrev}..${REMOTE}/${branch}|");
	for my $revision (<BRANCHREVS>)
	{
		chomp($revision);
		print("Preparing to write revision $revision\n");
		chdir("$GIT_ROOT/$project");

		system("git log -1 --format=format:\"\%B\%nCommitter: \%an - Date: \%aD\" $revision |grep -v git-svn-id >$COMMIT_MESG/${revision}") == 0
			or die("Could not get log message");

		my $svn_url = geturlforbranch($branch);

		open(COMMIT, "git svn commit-diff -r HEAD $revision~1 $revision  $svn_url -F $COMMIT_MESG/$revision 2>&1 |");
		while(<COMMIT>)
		{
			chomp;
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
			}
		}
		close(COMMIT);
	}
	close(BRANCHREVS);
}

sub parse_config_file 
{
    my ($File, $Config) = @_;
    my ($config_line, $Name, $Value);

    print("Loading $File\n");

    open(CONFIG, "$File")
	    or die("ERROR: Config file not found : $File");

    while (<CONFIG>) 
    {
        $config_line = $_;
        chomp($config_line);
        $config_line =~ s/^\s*//;
        $config_line =~ s/\s*$//;
        if (($config_line !~ /^#/) && ($config_line ne ""))
        {
            ($Name, $Value) = split (/=/, $config_line);
            $$Config{$Name} = $Value;
        }
    }

    close(CONFIG);
}

sub doimport
{
	mkpath $COMMIT_MESG;

	for my $projectconfig (glob "$GIT_ROOT/*.config")
	{
		my $project = $projectconfig;
		my %config;
		$project =~ s/(.*)\.config/\1/;
		parse_config_file($projectconfig,\%config);

		$SVN_BASE_URL = $config{"SVN_URL"};
		my $BRANCHES = $config{"BRANCH_ORDER"};
		@BRANCH_ORDER = split(",", $BRANCHES);
		$TRUNK = $BRANCH_ORDER[0];

		processproject(basename($project));
	}
}

doimport;

