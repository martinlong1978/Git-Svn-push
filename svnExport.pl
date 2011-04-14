#!/usr/bin/perl
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

sub branchfromparent
{
	my $project=$_[0];
	my $branch=$_[1];
	my $br_parent=$_[2];
	my $revision=$_[3];
	my $svn_from;
	
	if($br_parent eq $TRUNK)
	{
		$svn_from="$SVN_BASE_URL/trunk";
	}else{
		$svn_from="$SVN_BASE_URL/branches/$br_parent/trunk";
	}
	
	my $svn_to="$SVN_BASE_URL/branches/$branch/trunk";
	
	print "Branching $branch from $br_parent at rev $revision\n";

	my $svnrev=`cat $SVN_ROOT/$project.revcache |grep $revision |cut -d " " -f 1`;
	chomp($svnrev);
	
	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision") == 0 
		or die "Could not create tracking tag";
	
	#Branch and checkout working copy
	print "svn copy --parents  $svn_from\@$svnrev $svn_to -m \"Branch for $branch\"";
	system("svn copy --parents  $svn_from\@$svnrev $svn_to -m \"Branch for $branch\"") == 0
		or die "Could not create branch";
	mkpath "$SVN_ROOT/$project/$1";
	chdir "$SVN_ROOT/$project";
	system("svn co $svn_to $branch") == 0
		or die "Could not checkout branch";

}

sub createfirst
{
	my $project=$_[0];
	my $branch=$_[1];
	my $revision=$_[2];
	my $svn_url="$SVN_BASE_URL/trunk";

	print "New project branch: $branch\n";
	
	#Create tracking tag in GIT
	system("git tag -f svnbranch/$branch $revision") == 0
		or die "GIT Failure";
	
	#Create branch and checkout working copy
	system("svn mkdir --parents $svn_url -m \"First branch\"") == 0
		or die "Could not connect to $svn_url"; 
	mkpath "$SVN_ROOT/$project/$branch" 
		or die("Couldn't make svn temp store: $SVN_ROOT/$project/$branch");
	chdir "$SVN_ROOT/$project" 
		or die("Couldn't jump to svn temp store: $SVN_ROOT/$project/$branch");
	system("svn co $svn_url $branch") == 0
		or die "Could not connect to $svn_url";
}

sub findparent
{
	my $branch=$_[0];
	my $project=$_[1];
	print "Looking for parent of: $branch\n";
	open(REVS, "git rev-list --first-parent remotes/$REMOTE/$branch |") or die "Broken";
	my @revisions=<REVS>;
	close(REVS);
	
	open(REVCACHE, "$SVN_ROOT/$project.revcache");
	my %revcache = ();
	for my $cacheentry (<REVCACHE>)
	{
		chomp($cacheentry);
		my @entry = split(/ /, $cacheentry);
		$revcache{$entry[2]}=$entry[1];
	}
	close(REVCACHE);
	
	my $rev_last;
	for my $revision (@revisions)
	{
		chomp($revision);
		print "Looking for parent in rev: $revision\n";
		my $br_parent=$revcache{$revision};
		if($br_parent ne "")
		{
			&branchfromparent($project, $branch, $br_parent, $revision);
			return;
		}
		$rev_last=$revision;
	}
	&createfirst($project, $branch, $rev_last);	
}

sub processproject
{
	my $project=$_[0];
	print "Processing project: $project\n";
	
	chdir "$GIT_ROOT/$project" or die "Can't change to project directory: $project";
	
	system("git fetch --all") == 0
		or die "GIT fetch failed.";
	
	open(REFS, "git for-each-ref --format=\"\%(refname:short)\" refs/remotes/$REMOTE |grep -v HEAD|");
	my @allbranches=<REFS>;
	close(REFS);
	
	my @branches;
	
	for my $branch (@BRANCH_ORDER)
	{
		push(@branches, "$branch");
	}
	
	for my $branch (@allbranches)
	{
		chomp($branch);
		$branch=~s/$REMOTE\/(.*)/\1/;
		if(!grep($branch eq "$_", @BRANCH_ORDER))
		{
			push(@branches, $branch);
		}
	}

	print "Branches: @branches\n";
	
	for my $branch (@branches)
	{
		&processbranch($project, $branch);
	}
	
}

sub clearsvndir
{
	my $project=$_[0];
	my $svndir=$_[1];
	
	chdir $svndir or die "Couldn't cd to $svndir\n";
	
	system("svn up") == 0
		or die "Could not update working copy";
	
	# Delete any files that have been deleted in GIT (but dont delete .svn dirs)
	open(DELFILES, "find . |grep -v .svn|");
	for my $svnfile (<DELFILES>)
	{
		chomp($svnfile);
		$svnfile=~s/^\.\///;
		unless (-e "$GIT_ROOT/$project/$svnfile")
		{
			# Check it still exists... may have been deleted with a parent directory
			if (-e "$svnfile")
			{
				print "Deleting $svnfile from svn working copy\n";
				system("svn rm --force \"$svnfile\"") == 0
					or die "Could not delete $svnfile";
			}
		}
	}
	close(DELFILES);
}

sub processbranch
{
	my ($project, $branch) = ($_[0],$_[1]);
	print "Processing $branch of $project\n";

	chdir "$GIT_ROOT/$project" or die "Can't change to project directory: $project";
	
	my $tag=`git tag -l svnbranch/$branch | wc -l`;
	chomp($tag);
	if($tag < 1)
	{
		&findparent($branch, $project);
	}
	
	chdir "$GIT_ROOT/$project" or die "Can't change to project directory: $project";
	
	my $lastrev=`git show-ref -s --dereference svnbranch/$branch`;
	chomp($lastrev);
	
	print "Last revision synced: $lastrev\n";
	
	my $svndir="$SVN_ROOT/$project/$branch";
	
	mkpath $svndir;
	
	open(BRANCHREVS, "git rev-list --first-parent --reverse ${lastrev}..${REMOTE}/${branch}|");
	for my $revision (<BRANCHREVS>)
	{
		chomp($revision);
		print "Preparing to write revision $revision\n";
		chdir "$GIT_ROOT/$project";

		system("git checkout $revision") == 0
			or die "GIT checkout failed";
		system("git log -1 --format=format:\"\%B\%nCommitter: \%an - Date: \%aD\" |grep -v git-svn-id >$COMMIT_MESG/${revision}") == 0
			or die "Could not get log message";
		
		# Update and clear out any deleted files
		&clearsvndir($project, $svndir);
		
		system("cp -RT $GIT_ROOT/$project $svndir") == 0
			or die "Failed to sync dir: $GIT_ROOT/$project to: $svndir";
		
		system("rm -rf $svndir/.git") == 0
			or die "Could not remove .git dir from svn working copy";

		open(TOADD, "svn status |grep \?|");
		for my $path (<TOADD>)
		{
			chomp($path);
			if ("$path" ne "?" )
			{
				$path=~s/\?\s+(.*)/\1/;
				system("svn add \"$path\"") == 0
					or die "Could not add files to svn index";
			}
		}
		close(TOADD);
		
		system("svn commit -F $COMMIT_MESG/$revision") == 0
			or die "Commit failed.";
		system("svn up") == 0
			or die "Couldn't update SVN working copy";
		
		my $svnrev=`svn info |grep 'Last Changed Rev' | cut -d " " -f 4`;
		chomp($svnrev);
		
		open(REVCACHE, ">>$SVN_ROOT/$project.revcache");
		print REVCACHE "$svnrev $branch $revision\n";
		close(REVCACHE);
		
		chdir "$GIT_ROOT/$project";
		system("git tag -f svnbranch/$branch $revision") == 0
			or die "Could not create GIT tracking tag";

	}
	close(BRANCHREVS);
}

sub parse_config_file {

    my ($config_line, $Name, $Value, $Config, $File);

    ($File, $Config) = @_;
    
    print "Loading $File\n";

    open (CONFIG, "$File")
	    or die "ERROR: Config file not found : $File";

    while (<CONFIG>) {
        $config_line=$_;
        chomp ($config_line);          # Get rid of the trailling \n
        $config_line =~ s/^\s*//;     # Remove spaces at the start of the line
        $config_line =~ s/\s*$//;     # Remove spaces at the end of the line
        if ( ($config_line !~ /^#/) && ($config_line ne "") ){    # Ignore lines starting with # and blank lines
            ($Name, $Value) = split (/=/, $config_line);          # Split each line into name value pairs
            $$Config{$Name} = $Value;                             # Create a hash of the name value pairs
        }
    }

    close(CONFIG);

}

sub doimport
{
	mkpath $COMMIT_MESG;
	
	for my $projectconfig (glob "$GIT_ROOT/*.config")
	{
		my $project=$projectconfig;
		my %config;
		$project=~s/(.*)\.config/\1/;
		&parse_config_file($projectconfig,\%config);
		
		$SVN_BASE_URL=$config{"SVN_URL"};
		my $BRANCHES=$config{"BRANCH_ORDER"};
		@BRANCH_ORDER=split(",", $BRANCHES);
		$TRUNK=$BRANCH_ORDER[0];
		
		&processproject(basename($project));
	}

}

&doimport;

