#!/usr/bin/perl -w

# 2013-7 Bruno Contreras-Moreira (1) and Pablo Vinuesa (2):
# 1: http://www.eead.csic.es/compbio (Laboratory of Computational Biology, EEAD/CSIC/Fundacion ARAID, Spain)
# 2: http://www.ccg.unam.mx/~vinuesa (Center for Genomic Sciences, UNAM, Mexico)

# This script was originally written to compute the intersection between cluster lists produced
# by the different algorithms (BDBH, OMCL and COGs) implemented in get_homologues.pl.

# Takes as input the name of 1+ cluster directories generated by get_homologues.pl and get_homologues-est.pl,
# or alternatively a reference custom list of proteins (-r). Clusters must have at least an
# identical sequence to be comparable.

# Other tasks are documented when running the script without args or with -h option

$|=1;

use strict;
use Getopt::Std;
use File::Basename;
use File::Spec;
use FindBin '$Bin';
use lib "$Bin/lib";
use lib "$Bin/lib/bioperl-1.5.2_102/";
use phyTools;

my $RVERBOSE = 0;  # set to 1 to see R messages, helping explain why fitting fails
my @FEATURES2CHECK = ('EXE_R'); # cannot check EXE_PARS this way as it stalls

my $VENNCHARTLABELS = 1; # set to zero to prevent adding venn algorithm labels
my $SKIPINTERNALSTOPS = 1;
my $MAXSEQUENCENUMBERTAXON = 1000_000_000; # for XML reports

my $RFORBIDDENPATHCHARS = '#';

my ($INP_prot,$INP_synt,$INP_pange,$INP_taxa,$INP_include,$INP_ref,$INP_orthoxml,%opts) = (1,0,0,0,'',0,0);
my ($INP_tree,$INP_dirs,$INP_output_dir) = (0,'','');
my ($allparams,$dir,$file,$n_of_dirs,$corrected_name,$seqname,$seq,$gi,$id,$sequence,$dir2);
my ($ref_dir,$params,$n_of_taxa,$n_of_seqs,$neigh1,$neigh2,$list,$taxon,%included_input_files) = ('','');
my (@cluster_dirs,%stats,%set,%lists,%pangemat,%deprecated_clusters);

getopts('hTxmsrnt:o:d:I:', \%opts);

if(($opts{'h'})||(scalar(keys(%opts))==0))
{
  print   "\n[options]: \n";
  print   "-h \t this message\n";
  print   "-d \t comma-separated names of cluster directories                  (min 1 required, example -d dir1,dir2)\n";
  print   "-o \t output directory                                              (required, intersection cluster files are copied there)\n";
  print   "-n \t use nucleotide sequence .fna clusters                         (optional, uses .faa protein sequences by default)\n";
  print   "-r \t take first cluster dir as reference set, which might contain  (optional, by default cluster dirs are expected\n";
  print   "   \t a single representative sequence per cluster                   to be derived from the same taxa; overrides -t,-I)\n";
  print   "-s \t use only clusters with syntenic genes                         (optional, parses neighbours in FASTA headers)\n";
  print   "-t \t use only clusters with single-copy orthologues from taxa >= t (optional, default takes all intersection clusters; example -t 10)\n";
  print   "-I \t produce clusters with single-copy seqs from ALL taxa in file  (optional, example -I include_list; overrides -t)\n";
  print   "-m \t produce intersection pangenome matrices                       (optional, ideally expects cluster directories generated\n";
  print   "   \t                                                                with get_homologues.pl -t 0)\n";
  print   "-x \t produce cluster report in OrthoXML format                     (optional)\n";
  print   "-T \t produce parsimony-based pangenomic tree                       (optional, requires -m)\n\n";
  exit(-1);
}

if(defined($opts{'r'})){ $INP_ref = 1 }

if(defined($opts{'d'}))
{
  $INP_dirs = $opts{'d'};
  foreach $dir (split(/\,/,$INP_dirs))
  {
    $dir =~ s/\/+$//;
    if(-s $dir)
    {
      if($INP_ref && scalar(@cluster_dirs) == 2)
      {
        die "\n# $0 : please use only two input dirs with -r\n";
      }
      push(@cluster_dirs,$dir);

      # see if cluster_list file is in place, which is optional
      $list = $dir . '.cluster_list';
      if(-s $list){ $lists{$dir} = $list; }
    }
    else{ die "\n# $0 : cannot find directory $dir , please check\n"; }
  }

  if(@cluster_dirs && scalar(@cluster_dirs)<1)
  {
    die "\n# $0 : need at least 2 cluster directories to run (".
      scalar(@cluster_dirs)."), exit\n";
  }
}
else{ die "\n# $0 : need -d parameter, exit\n"; }

if(defined($opts{'o'}))
{
  $INP_output_dir = $opts{'o'};
  if($INP_output_dir =~ /\/$/){ $INP_output_dir =~ s/\/$// }
}
else{ die "\n# $0 : need -o parameter, exit\n"; }

if(defined($opts{'n'})){ $INP_prot = 0 }

if(defined($opts{'m'}))
{
  $INP_pange = 1;
  if(defined($opts{'T'})){ $INP_tree = 1 }
}

if(defined($opts{'x'})){ $INP_orthoxml = 1 }

if(defined($opts{'I'}) && !$INP_ref)
{
  $INP_include = $opts{'I'};
  $params .= '_I'.basename($INP_include);
}
else
{
  if(defined($opts{'t'}) && !$INP_ref){ $INP_taxa = $opts{'t'} }
  $params = "_t$INP_taxa";
}

if(defined($opts{'s'}))
{
  $INP_synt = 1;
  $params .= '_s';
}

printf("\n# %s -d %s -o %s -n %d -m %d -t %d -I %s -r %d -s %d -x %d -T %d\n",
  $0,$INP_dirs,$INP_output_dir,!$INP_prot,$INP_pange,$INP_taxa,
  $INP_include,$INP_ref,$INP_synt,$INP_orthoxml,$INP_tree);

#################################### MAIN PROGRAM  ################################################

$n_of_dirs = scalar(@cluster_dirs);
print "\n# number of input cluster directories = $n_of_dirs\n\n";

## 1) read cluster files in all input dirs

# first parse include_file if required
if($INP_include)
{
  open(INCL,$INP_include) || die "# EXIT : cannot read $INP_include\n";
  while(<INCL>)
  {
    next if(/^#/ || /^$/);
    chomp($_);
    $included_input_files{$_} = 1;
  }
  close(INCL);

  print "# included taxa = ".scalar(keys(%included_input_files))."\n\n";
}

foreach my $d (0 .. $#cluster_dirs)
{
  my ($n_of_clusters,@files,%taxa,@dir_keys) = (0);
  $dir = $cluster_dirs[$d];

  print "# parsing clusters in $dir ...\n";
  if($ref_dir eq ''){ $ref_dir = $d }

  # if cluster_list is there use it to parse cluster names and taxa (preferred option)
  if($lists{$dir} && -s $lists{$dir})
  {
    print "# cluster_list in place, will parse it ($lists{$dir})\n";

    open(LIST,$lists{$dir}) || die "# $0 : cannot read list file $lists{$dir}\n";
    while(<LIST>)
    {
      #cluster 1351_YP_802849.1 size=4 taxa=4 file: 1351_YP_802849.1.faa dnafile: void
      #: Buch_aph_Cc.faa
      # cluster 1-76864_yacE-76865_guaC size=20 taxa=20 dnafile: 1-76864_yacE-76865_guaC.fna
      # cluster 3491_1182 size=20 taxa=20 dnafile: 3491_1182.fna
      # cluster 76767_thrA size=20 taxa=20 Pfam=PF00696, file: 76767_thrA.faa dnafile: 76767_thrA.fna
      # cluster 1_Brdisv1ABR21035063m size=58 taxa=55 file: 1_Brdisv1ABR21035063m.fna aminofile: 1_Brdisv1ABR21035063m.faa
      # cluster 1_TR20326-c1_g1_i1 size=12 taxa=12 Pfam=PF13920, file: 1_TR20326-c1_g1_i1.fna aminofile: 1_TR20326-c1_g1_i1.faa
            
      if(/^cluster \S+ size=\d+ taxa=\d+ .*?file: (\S+) dnafile: (\S+)/)
      {
        if($INP_prot){ $file = $1 }
        else{ $file = $2 }

        if($file ne 'void'){ push(@files,$file) }
      }
      elsif(/^cluster \S+ size=\d+ taxa=\d+ dnafile: (\S+)/)
      {
        $file = $1;
        push(@files,$file);
      }
      elsif(/^cluster \S+ size=\d+ taxa=\d+ file: (\S+) aminofile: (\S+)/ || 
        /^cluster \S+ size=\d+ taxa=\d+ .*?file: (\S+) aminofile: (\S+)/)
      {
        if($INP_prot){ $file = $2 }
        else{ $file = $1 }

        if($file ne 'void'){ push(@files,$file); }
      }
      elsif(/^: (\S+)/ && $file ne 'void')
      {
        $taxa{$file}{$1}++;

        #print "$taxa{$file}{$1}\n" if($taxa{$file}{$1}>1);
        push(@{$taxa{$file}{'sorted_taxa'}},$1);
      }
    }
    close(LIST); 
  }
  else # parsing all faa/fna files contained in $dir
  {
    print "# no cluster list in place, checking directory content ...\n" .
      "# WARNING: [taxon names] will be automatically extracted from FASTA headers,\n" .
      "# please watch out for errors\n\n";

    opendir(DIR,$dir) || die "# $0 : cannot list $dir\n";
    if($INP_prot){ @files = grep {!/\.fna/} grep {!/^\./} readdir(DIR) }
    else{ @files = grep {!/\.faa/} grep {!/^\./} readdir(DIR) }
    closedir(DIR);
  }

  if(!@files)
  {
    if($INP_prot)
    {
      die "\n# cannot find any .faa files in $dir,exit\n".
        "# perhaps you might try -n flag\n";
    }
    else{ die "\n# cannot find any .fna files in $dir,exit\n" }
  }

  foreach $file (@files)
  {
    next if(-d "$dir/$file"); #print "$dir/$file\n";

    # read sequences in each cluster
    my ($clusterkey,$cluster_data,$n_of_cluster_seqs,$taxon_name) = ('','',0);
    my (@choppedseqs,@clusterseqs,%cluster_taxa,@gis,@neighbors,@sorted_taxa);
    my $cluster_ref = read_FASTA_file_array("$dir/$file");

    if($taxa{$file}) # previously read from .cluster_list file
    {
      %cluster_taxa = %{$taxa{$file}};
      delete($cluster_taxa{'sorted_taxa'}); # otherwise it would count as one extra taxa; conserved in %taxa
      #Uncultured_bacterium_plasmid_pRSB205.gb 1
    }
    else # automatically extracted from headers, error prone
    {
      my %cluster_taxa_in_headers = find_taxa_FASTA_array_headers($cluster_ref,1);
      
      foreach $taxon (keys(%cluster_taxa_in_headers))
      { 
        $taxon_name = $taxon;
        $taxon_name =~ s/\[|\]//g; 
        $cluster_taxa{$taxon_name} = $cluster_taxa_in_headers{$taxon}{'SIZE'};
      } 
      
      foreach $seq (0 .. $#{$cluster_ref})
      {
        foreach $taxon (keys(%cluster_taxa_in_headers))
        {
          if(grep(/^$seq$/,@{$cluster_taxa_in_headers{$taxon}{'MEMBERS'}}))
          {
            $taxon_name = $taxon;
            $taxon_name =~ s/\[|\]//g; 
            push(@{$taxa{$file}{'sorted_taxa'}},$taxon_name);
          }
        }
      }
    }
    $n_of_taxa = scalar(keys(%cluster_taxa));

    # if requested skip clusters with different taxa/seq composition
    if($INP_taxa && $n_of_taxa == 0)
    {
      die "# $0 : cannot apply option -t $INP_taxa when cluster sequences lack [taxon names]\n";
    }
    if($INP_include && $n_of_taxa == 0)
    {
      die "# $0 : cannot apply option -I when cluster sequences lack [taxon names]\n";
    }

    # if requested consider only single-copy clusters with taxa >= $INP_taxa
    next if($INP_taxa && ($n_of_taxa < $INP_taxa || $#{$cluster_ref} != $n_of_taxa-1));

    foreach $seq (0 .. $#{$cluster_ref})
    {
      # in case of missing nucleotide sequences, not retrieved from gbk files
      $cluster_ref->[$seq][SEQ] ||= '--unknown sequence--';

      # check for internal STOP codons if required
      next if($SKIPINTERNALSTOPS && $cluster_ref->[$seq][SEQ] =~ /\*[A-Z]/i);

      # fix header and remove possibly added bits: |intergenic199|,| aligned:1-296 (296)
      $seqname = $cluster_ref->[$seq][NAME];

      next if($INP_include && !$included_input_files{$taxa{$file}{'sorted_taxa'}->[$seq]});
      push(@sorted_taxa,$taxa{$file}{'sorted_taxa'}->[$seq]);

      # store gi and/or neighbor (synteny) data if required
      # NOTE: assumes GI is first space-separated label in header
      # GI:15616631 |[B aphidicola (Acyrthosiphon pisum)]|APS|gidA|1887|NC_002528(640681):197-2083:1
      #^..^ ...|neighbours:start(),GI:15616(1)
      if($INP_synt || $INP_orthoxml)
      {
        $gi = (split(/\s/,$seqname))[0]; $gi =~ s/ //g;
        push(@gis,$gi); #print "$gi\n";
        if($INP_synt && $seqname =~ /neighbours:(\S+?)\(.*?\),(\S+?)\(/)
        {

          # take both neighbors to make sure strand does not matter
          ($neigh1,$neigh2) = ($1,$2); #print "$neigh1,$neigh2\n";
          if($neigh1 ne 'start'){ push(@neighbors,$neigh1) }
          if($neigh2 ne 'end'){ push(@neighbors,$neigh2) }
        }
      }

      if($seqname =~ /intergenic/){ $seqname =~ s/^\d+ //; }
      if($seqname =~ / \| aligned/){ $seqname = (split(/ \| aligned/,$seqname))[0]; }

      if($n_of_dirs == 1)
      {

        # avoid duplicated clusters when all you want is a pangenmatrix
        push(@clusterseqs,$seqname.'<SEQ>'.$cluster_ref->[$seq][SEQ]);
      }
      else{ push(@clusterseqs,$cluster_ref->[$seq][SEQ]); }

      $cluster_data .= ">$seqname\n$cluster_ref->[$seq][SEQ]\n";
      $n_of_cluster_seqs++;
    }

    next if($INP_include && $n_of_cluster_seqs != scalar(keys(%included_input_files)));

    # make unique cluster key by sorting and joining sequences
    # cut first 3 and last 3 residues to avoid start and stop codon issues
    @choppedseqs = map {substr($_,3,-3)} @clusterseqs;
    $clusterkey = join(' ',(sort(@choppedseqs)));

    if(!defined($stats{$clusterkey}{$d}))
    {
      $corrected_name = $file;
      $corrected_name =~ s/['|\(]//g;
      $stats{$clusterkey}{'file_name'} = $corrected_name;
      $stats{$clusterkey}{'fasta'} = $cluster_data;
      $stats{$clusterkey}{'taxa'} = \%cluster_taxa;
      $stats{$clusterkey}{'sorted_taxa'} = \@sorted_taxa;
      if($INP_synt || $INP_orthoxml)
      {
        $stats{$clusterkey}{'gis'} = \@gis;
        if($INP_synt)
        {
          $stats{$clusterkey}{'neighbors'} = \@neighbors;
          push(@dir_keys,$clusterkey);
        }
        else{ $stats{$clusterkey}{'sequences'} = \@clusterseqs }
      }

      $n_of_clusters++;
      $stats{$clusterkey}{'total'}++;
      $stats{$clusterkey}{$d} = 1;
    }
    else
    {
      print "# WARNING: skipping cluster $file , seems to duplicate $stats{$clusterkey}{'file_name'}\n";
    }
  }

  # check cluster members are actually syntenic
  if($INP_synt)
  {
    my ($key,$key2,$ref_gis,$ref_neighbors,$ref_sorted_taxa);
    my ($taxa1,$taxa2,$taxa_matched);
    my $n_of_syntenic_clusters = 0;
    foreach $key (@dir_keys)
    {
      $ref_neighbors = $stats{$key}{'neighbors'};
      $taxa1 = join(',',sort(keys(%{$stats{$key}{'taxa'}})));
      CLUSTER2: foreach $key2 (@dir_keys)
      {
        next if($key eq $key2);
        $taxa2 = join(',',sort(keys(%{$stats{$key2}{'taxa'}})));
        next if($taxa1 ne $taxa2); #print "$taxa1 ne $taxa2\n";

        # check whether cluster key2 is contained within neighbors
        my %matched_taxa;
        $ref_gis = $stats{$key2}{'gis'};
        $ref_sorted_taxa = $stats{$key2}{'sorted_taxa'};

        foreach $gi (0 .. $#{$ref_gis})
        {

          # allowing inparalogues in clusters, only the syntenic gene matters
          if(grep(/^$ref_gis->[$gi]$/,@$ref_neighbors))
          {
            $matched_taxa{$ref_sorted_taxa->[$gi]}=1;
          }
        }
        next if(!%matched_taxa);
        $taxa_matched = join(',',sort(keys(%matched_taxa)));
        next if($taxa1 ne $taxa_matched); #print "$taxa1 ne $taxa_matched\n";

        # all gis successfully matched: this is probably a syntenic cluster
        $stats{$key}{'syntenic'}++; #print "$stats{$key}{'file_name'} $stats{$key2}{'file_name'}\n";
        $n_of_syntenic_clusters++;
        last CLUSTER2;
      }
    }

# warning: a cluster can fail to be syntenic in one directory but confirmed as such in another,
# thus removed the total number to avoid confusions
#print "# number of clusters = $n_of_clusters syntenic = $n_of_syntenic_clusters\n";
  }

  print "# number of clusters = $n_of_clusters\n";
}

## 2) calculate intersection clusters

# create output folder and put log file there
my $n_of_clusters = 0;
print "\n# intersection output directory: $INP_output_dir\n";

if(!-s $INP_output_dir){ mkdir($INP_output_dir); }
else
{
  print "# WARNING: output directory $INP_output_dir already exists, ".
    "note that you might be mixing clusters from previous runs\n\n";
}

my $intersection_file = $INP_output_dir."/intersection$params\.cluster_list";

open(LIST,">$intersection_file") || die "# $0 : cannot create $intersection_file";
printf LIST ("# %s parameters: -n %d -m %d -t %d -s %d\n# -d %s\n# -o %s\n# -I %s\n# -r %s\n",
  $0,!$INP_prot,$INP_pange,$INP_taxa,$INP_synt,$INP_dirs,$INP_output_dir,$INP_include,$INP_ref);

# if $INP_ref check whether there is a single non-refence cluster which contains each reference cluster;
# reference clusters might contain less taxa than the (non-reference) rest
if($INP_ref)
{
  my @keys = (keys(%stats));
  foreach my $key (@keys)
  {
    next if($INP_synt && !$stats{$key}{'syntenic'});
    if($stats{$key}{$ref_dir})
    {
      my @indkeys = split(/ /,$key);
      my @candidate_clusters;
      foreach my $key2 (@keys)
      {
        next if($stats{$key2}{$ref_dir});
        next if($INP_synt && !$stats{$key2}{'syntenic'});
        my $n_of_matched_ref_keys = 0;
        foreach my $indkey (@indkeys)
        {
          if($key2 =~ /$indkey/)
          {
            $n_of_matched_ref_keys++;
          }
        }
        if($n_of_matched_ref_keys == scalar(@indkeys))
        {
          push(@candidate_clusters,$key2);
        }
      }
      if(scalar(@candidate_clusters) == 1 && # unique
        $stats{$candidate_clusters[0]}{'total'} == $n_of_dirs-1)
      {
        $stats{$candidate_clusters[0]}{'total'}++;
        $stats{$candidate_clusters[0]}{$ref_dir}++;

        # name these clusters with gene names from reference dir for convenience
        $stats{$candidate_clusters[0]}{'file_name'} = $stats{$key}{'file_name'};

        # contains reference clusters alreay merged with non-reference
        $deprecated_clusters{$key}=1;
      }
    }
  }
}

my @intersection_keys;
foreach my $key (keys(%stats))
{
  # intersection steps
  next if($stats{$key}{'total'} != $n_of_dirs);

  next if($INP_synt && !$stats{$key}{'syntenic'});

  push(@intersection_keys,$key);
  print LIST "$stats{$key}{'file_name'}\n";

  $file = $INP_output_dir.'/'.$stats{$key}{'file_name'};

  # keep track of intersection pangenome
  if($INP_pange)
  {
    foreach $taxon (keys (%{$stats{$key}{'taxa'}}))
    {
      $pangemat{$taxon}{$stats{$key}{'file_name'}} = $stats{$key}{'taxa'}{$taxon};
    }
  }

  open(FASTA,">$file") || die "# $0 : cannot create $file\n";
  print FASTA $stats{$key}{'fasta'};
  close(FASTA);

  $n_of_clusters++;
}

print LIST "# intersection size = $n_of_clusters clusters\n";
close(LIST);

if($INP_synt){ print "# intersection size = $n_of_clusters clusters (syntenic)\n\n"; }
else{ print "# intersection size = $n_of_clusters clusters\n\n"; }

print "# intersection list = $intersection_file\n\n";

# print OrthoXML report (http://orthoxml.org/xml/Main.html) if required
# Schmitt, T., Messina, D.N., Schreiber, F. and Sonnhammer, E.L. (2011) Letter to the editor: SeqXML and OrthoXML:
# standards for sequence and orthology information. Brief Bioinform, 12, 485-488.
if($INP_orthoxml)
{
  my ($n_of_taxaid,$n_of_cluster,$cluster,%taxon_id,%taxon_seqs,%taxon_sequences,@clusters,@cluster_taxa) = (0,1);
  my $seqtag = 'AAseq'; if(!$INP_prot){ $seqtag = 'DNAseq' }

  foreach my $key (@intersection_keys)
  {
    $cluster = "<orthologGroup id=\"$n_of_cluster\">\n";

    $n_of_seqs = $#{$stats{$key}{'sorted_taxa'}};
    foreach $seq (0 .. $n_of_seqs)
    {
      $taxon = $stats{$key}{'sorted_taxa'}->[$seq];
      $gi = $stats{$key}{'gis'}->[$seq];
      $sequence = $stats{$key}{'sequences'}->[$seq];
      $sequence =~ s/^.*?<SEQ>//;

      if(!$taxon_id{$taxon})
      {
        $n_of_taxaid++;
        $taxon_id{$taxon} = $n_of_taxaid * $MAXSEQUENCENUMBERTAXON;
        push(@cluster_taxa,$taxon);
      }
      else{ $taxon_id{$taxon}++ }

      $id = $taxon_id{$taxon};

      push(@{$taxon_sequences{$taxon}},"<entry id=\"$gi\" source=\"$taxon\"><$seqtag>$sequence</$seqtag></entry>");
      push(@{$taxon_seqs{$taxon}},"<gene id=\"$id\" geneId=\"$gi\" protId=\"$gi\"/>");

      $cluster .= "<geneRef id=\"$id\"></geneRef>\n"; #print "$id $taxon $gi\n";
    }

    $cluster .= "</orthologGroup>\n";

    push(@clusters,$cluster);

    $n_of_cluster++;
  }

  # actually print report, following examples:
  # http://www.orthoxml.org/0.3/examples/orthoxml_example_v0.3.xml
  # http://www.seqxml.org/0.4/examples/seqxml_example_v0.4.xml

  my $seqxml_report_file = $INP_output_dir . "/sequences$params\.xml";
  open(SEQXML,">$seqxml_report_file") || die "# $0 : cannot create $seqxml_report_file";

  my $orthoxml_report_file = $INP_output_dir . "/report$params\.xml";
  open(XML,">$orthoxml_report_file") || die "# $0 : cannot create $orthoxml_report_file";

  print XML "<orthoXML version=\"0.3\" origin=\"get_homologues\" xsi:schemaLocation=\"http://www.orthoxml.org/0.3/orthoxml.xsd\">\n";
  print XML "<notes>\nFile created with command: ";
  printf XML ("%s parameters: -n %d -m %d -t %d -s %d\n# -d %s\n# -o %s\n# -I %s\n# -r %s\n",
    $0,!$INP_prot,$INP_pange,$INP_taxa,$INP_synt,$INP_dirs,$INP_output_dir,$INP_include,$INP_ref);
  print XML "</notes>\n";

  foreach $taxon (@cluster_taxa)
  {
    print XML "<species name=\"$taxon\" NCBITaxId=\"\">\n";
    print XML "<database name=\"\" version=\"$taxon\">\n";
    print XML "<genes>\n";
    foreach $gi (@{$taxon_seqs{$taxon}}){ print XML "$gi\n" }
    print XML "</genes>\n</database>\n</species>\n";

    print SEQXML "<seqXML seqXMLversion=\"0.4\" xsi:noNamespaceSchemaLocation=\"http://www.seqxml.org/0.4/seqxml.xsd\">\n";
    foreach $sequence (@{$taxon_sequences{$taxon}}){ print SEQXML "$sequence\n" }
    print SEQXML "</seqXML>\n";
  }

  print XML "<groups>\n";
  foreach $cluster (@clusters){ print XML "$cluster\n"; }
  print XML "</groups>\n";
  print XML "</orthoXML>\n";

  close(XML);
  close(SEQXML);

  print "# OrthoXML report file = $orthoxml_report_file\n";
  print "# SEQXML sequence file = $seqxml_report_file\n\n";
}

## 3) intersection pangenome matrices
if($INP_pange && %pangemat)
{
  my $pangenome_phylip_file = $INP_output_dir . "/pangenome_matrix$params\.phylip";
  my $pangenome_fasta_file  = $INP_output_dir . "/pangenome_matrix$params\.fasta";
  my $pangenome_matrix_file = $INP_output_dir . "/pangenome_matrix$params\.tab";
  my $pangenome_csv_tr_file = $INP_output_dir . "/pangenome_matrix$params\.tr.csv"; # tr = transposed

  # 1) sort clusters
  my @taxon_names = keys(%pangemat);
  my (%cluster_names,$cluster_name,$file_number,%file_name);
  for($taxon=0;$taxon<scalar(@taxon_names);$taxon++)
  {
    foreach $cluster_name (keys(%{$pangemat{$taxon_names[$taxon]}}))
    {
      next if($cluster_names{$cluster_name});
      $cluster_names{$cluster_name} = 1;
    }
  }
  my @cluster_names = sort {(split(/\D/,$a,2))[0]<=>(split(/\D/,$b,2))[0]} (keys(%cluster_names));

  # tab-separated matrix
  open(PANGEMATRIX,">$pangenome_matrix_file")
    || die "# EXIT: cannot create $pangenome_matrix_file\n";

  print PANGEMATRIX 'source:'.File::Spec->rel2abs($INP_output_dir)."\t";
  foreach $cluster_name (@cluster_names){ print PANGEMATRIX "$cluster_name\t"; }
  print PANGEMATRIX "\n";
  for($taxon=0;$taxon<scalar(@taxon_names);$taxon++)
  {
    print PANGEMATRIX "$taxon_names[$taxon]\t";
    foreach $cluster_name (@cluster_names)
    {
      if($pangemat{$taxon_names[$taxon]}{$cluster_name})
      {
        print PANGEMATRIX "$pangemat{$taxon_names[$taxon]}{$cluster_name}\t";
      }
      else{ print PANGEMATRIX "0\t"; }
    }
    print PANGEMATRIX "\n";
  }

  close(PANGEMATRIX);

  print "# pangenome_file = $pangenome_matrix_file\n";

  # version in phylip format http://evolution.genetics.washington.edu/phylip/doc/discrete.html
  open(PANGEMATRIX,">$pangenome_phylip_file")
    || die "# EXIT: cannot create $pangenome_phylip_file\n";

  # FASTA-format file with binary data as sequence, for IQ-TREE 
  open(PANGEMATRIX2,">$pangenome_fasta_file")
      || die "# EXIT: cannot create $pangenome_fasta_file\n";

  printf PANGEMATRIX ("%10d    %d\n",scalar(@taxon_names),scalar(@cluster_names));
  for($taxon=0;$taxon<scalar(@taxon_names);$taxon++)
  {
    $file_number = sprintf("%010d",$taxon);
    printf PANGEMATRIX ("%s    ",$file_number);

    print PANGEMATRIX2 ">$taxon_names[$taxon]\n";

    $file_name{$file_number}{'NAME'} = $taxon_names[$taxon];

    foreach $cluster_name (@cluster_names)
    {
      if($pangemat{$taxon_names[$taxon]}{$cluster_name})
      {
        print PANGEMATRIX "1";
        print PANGEMATRIX2 "1";
      }
      else
      { 
        print PANGEMATRIX "0"; 
        print PANGEMATRIX2 "0";
      }
    }
    print PANGEMATRIX "\n";
    print PANGEMATRIX2 "\n";
  }

  close(PANGEMATRIX2);

  close(PANGEMATRIX);

  # transposed version in CSV format for Scoary https://github.com/AdmiralenOla/Scoary
  open(PANGEMATRIXCSV,">$pangenome_csv_tr_file")
    || die "# EXIT: cannot create $pangenome_csv_tr_file\n";

  # add header
  my $simple_taxon;  
  print PANGEMATRIXCSV "Gene,Non-unique Gene name,Annotation,No. isolates,No. sequences,Avg sequences per isolate,".
    "Genome fragment,Order within fragment,Accessory Fragment,Accessory Order with Fragment,QC,Min group size nuc,".
    "Max group size nuc,Avg group size nuc";
  for($taxon=0;$taxon<scalar(@taxon_names);$taxon++)
  {
    $simple_taxon = $taxon_names[$taxon];
    $simple_taxon =~ s/ /_/g;
    $simple_taxon =~ s/[\s|\(|\)|\*|;|\|\[|\]|\/|:|,|>|&|<]/-/g;
    print PANGEMATRIXCSV ",$simple_taxon";
  } print PANGEMATRIXCSV "\n";

  foreach $cluster_name (@cluster_names)
  {
    print PANGEMATRIXCSV "$cluster_name,,,,,,,,,,,,,"; # Roary fields empty as they're not used by Scoary

    for($taxon=0;$taxon<scalar(@taxon_names);$taxon++)
    {
      if($pangemat{$taxon_names[$taxon]}{$cluster_name})
      {
        print PANGEMATRIXCSV ",1";
      }  
      else{ print PANGEMATRIXCSV ",0" }
    } print PANGEMATRIXCSV "\n";
  }
  close(PANGEMATRIXCSV);

  print "# pangenome_phylip file = $pangenome_phylip_file\n";
  print "# pangenome_FASTA file = $pangenome_fasta_file\n";
  print "# pangenome CSV file (Scoary) = $pangenome_csv_tr_file\n";
    
  print "\n# NOTE: matrix can be transposed for your convenience with:\n\n";
  
print <<'TRANS';
  perl -F'\t' -ane '$r++;for(1 .. @F){$m[$r][$_]=$F[$_-1]};$mx=@F;END{for(1 .. $mx){for $t(1 .. $r){print"$m[$t][$_]\t"}print"\n"}}' \
TRANS

  print "   $pangenome_matrix_file\n\n";

  if($INP_tree)
  {
    my $pangenome_phylip_log = $INP_output_dir . "/pangenome_matrix$params\.phylip.log";
    my $pangenome_tree_file  = $INP_output_dir . "/pangenome_matrix$params\.phylip.ph";

    run_PARS($pangenome_phylip_file,$pangenome_tree_file,$pangenome_phylip_log,\%file_name);

    if(-s $pangenome_tree_file && -s $pangenome_phylip_log)
    {
      print "\n# parsimony results by PARS (PHYLIP suite, http://evolution.genetics.washington.edu/phylip/doc/pars.html):\n";
      print "# pangenome_phylip tree = $pangenome_tree_file\n";
      print "# pangenome_phylip log = $pangenome_phylip_log\n\n";
    }
  }
}

## 4) calculate Venn diagram if R is available
if($n_of_dirs <=3 && $n_of_dirs > 1)
{
  my ($k,@venn,@sector,$shortn,$shortn2);
  my $tmp_input_file = $INP_output_dir.'/_input_file_list.txt';
  my $venn_file = $INP_output_dir."/venn$params\.pdf";

  if(-s $venn_file){ unlink($venn_file) }

  check_installed_features(@FEATURES2CHECK);
  my $Rok = feature_is_installed('R');

  # prepare data
  my @keys = keys(%stats);
  for($k=0;$k<=$#keys;$k++)
  {
    next if($INP_synt && !$stats{$keys[$k]}{'syntenic'});

    foreach my $d (0 .. $#cluster_dirs)
    {
      $dir = $cluster_dirs[$d];
      next if($deprecated_clusters{$keys[$k]});
      if($stats{$keys[$k]}{$d})
      {
        push(@{$set{$d}},$stats{$keys[$k]}{'file_name'}.'_'.$keys[$k]);
      }
    }
  }

  # check file paths are valid for R
  foreach my $d (0 .. $#cluster_dirs)
  {
    $dir = $cluster_dirs[$d];
    if($dir =~ /homologues/){ $dir = $INP_output_dir.(split(/homologues.*?\//,$dir))[1]; }
    else{ $dir = $INP_output_dir.basename($dir) }

    if($dir =~ /($RFORBIDDENPATHCHARS)/)
    {
      die "\n# ERROR: cannot create a Venn diagram with these data, ".
        "as file paths contain forbidden char(s): $1\n";
    }
  }

  open(TMPIN,">$tmp_input_file") || die "# $0 : cannot create $tmp_input_file\n";
  foreach my $d (0 .. $#cluster_dirs)
  {
    $dir = $cluster_dirs[$d];
    
    push(@venn,$set{$d}); # one array ref per data set
    if($dir =~ /homologues/){ $shortn = (split(/homologues.*?\//,$dir))[1]; }# short name
    else{ $shortn = basename($dir) }

    my $dirvennfile = $INP_output_dir.'/' . $shortn . ".venn$params.txt";
    my $sectorfile  = $INP_output_dir.'/unique_' . $shortn . ".venn$params.txt";

    if(-s $sectorfile){ unlink($sectorfile) }

    if($shortn =~ /_dmd.*alg([A-Z]+)/){ $shortn = "dmd_$1"; }
    elsif($shortn =~ /alg([A-Z]+)/){ $shortn = $1; }
    if(!$VENNCHARTLABELS){ $shortn = '' }

    open(VENNDATA,">$dirvennfile") || die "# $0 : cannot write to $dirvennfile\n";
    foreach $k (@{$set{$d}}){ print VENNDATA "$k\n"; }
    close(VENNDATA);
    print "# input set: $dirvennfile\n";
    print TMPIN "$dirvennfile\t$shortn\t$sectorfile\n";
    push(@venn,$dirvennfile);
    push(@sector,$sectorfile);
  }
  
  # add intersections of two sets if there are 3 sets in total
  if($#cluster_dirs == 2)
  {
    foreach my $d (0 .. $#cluster_dirs-1)
    {
      $dir = $cluster_dirs[$d];
      if($dir =~ /homologues/){ $shortn = (split(/homologues.*?\//,$dir))[1]; }
      else{ $shortn = basename($dir) }
    
      foreach my $d2 ($d+1 .. $#cluster_dirs)
      {
        $dir2 = $cluster_dirs[$d2];
        if($dir2 =~ /homologues/){ $shortn2 = (split(/homologues.*?\//,$dir2))[1]; }
        else{ $shortn2 = basename($dir2) }
        
        my $sectorfile = $INP_output_dir.'/intersection_' . $shortn . '_' . $shortn2 .".venn$params.txt";
        
        if(-s $sectorfile){ unlink($sectorfile) }

        print TMPIN "$sectorfile\t$sectorfile\t$sectorfile\n";
        push(@sector,$sectorfile);
      }
    }       
  }
  
  close(TMPIN);

  if($Rok)
  {
    my $Rparams = '';
    if(!$RVERBOSE){ $Rparams = '-q 2>&1 > /dev/null' }

    open(RSHELL,"|R --no-save $Rparams ") || die "# $0 : cannot call R: $!\n";
    print RSHELL<<EOF;

options(warn=-1) 

circle <- function(x, y, r, ...) 
{
    ang <- seq(0, 2*pi, length = 100)
    xx <- x + r * cos(ang)
    yy <- y + r * sin(ang)
    polygon(xx, yy, ...)
}

# adapted from http://stackoverflow.com/questions/1428946/venn-diagrams-with-r
venndia <- function(labels, A, B, C, ...)
{
    cMissing <- missing(C)
    if(cMissing){ C <- c() }
    
    unionAB <- union(A, B) 
    unionAC <- union(A, C)
    unionBC <- union(B, C)
    uniqueA <- setdiff(A, unionBC)
    uniqueB <- setdiff(B, unionAC)
    uniqueC <- setdiff(C, unionAB)
    intersAB <- setdiff(intersect(A, B), C)
    intersAC <- setdiff(intersect(A, C), B)
    intersBC <- setdiff(intersect(B, C), A)
    intersABC <- intersect(intersect(A, B), intersect(B, C))
    nA <- length(uniqueA)       
    nB <- length(uniqueB)
    nC <- length(uniqueC)
    nAB <- length(intersAB)
    nAC <- length(intersAC)
    nBC <- length(intersBC)
    nABC <- length(intersABC)   
	
    # shorten element labels in relevant lists/sectors
    uniqueA = gsub(pattern=".faa_.+",replacement=".faa", uniqueA)
    uniqueA = gsub(pattern=".fna_.+",replacement=".fna", uniqueA)
    uniqueB = gsub(pattern=".faa_.+",replacement=".faa", uniqueB)
    uniqueB = gsub(pattern=".fna_.+",replacement=".fna", uniqueB)
    uniqueC = gsub(pattern=".faa_.+",replacement=".faa", uniqueC)
    uniqueC = gsub(pattern=".fna_.+",replacement=".fna", uniqueC)
    intersABC = gsub(pattern=".faa_.+",replacement=".faa", intersABC)
    intersABC = gsub(pattern=".fna_.+",replacement=".fna", intersABC)
    intersAB = gsub(pattern=".faa_.+",replacement=".faa", intersAB)
    intersAB = gsub(pattern=".fna_.+",replacement=".fna", intersAB)
    intersAC = gsub(pattern=".faa_.+",replacement=".faa", intersAC)
    intersAC = gsub(pattern=".fna_.+",replacement=".fna", intersAC)
    intersBC = gsub(pattern=".faa_.+",replacement=".faa", intersBC)
    intersBC = gsub(pattern=".fna_.+",replacement=".fna", intersBC)
    
    pdf(file='$venn_file')
    par(mar=c(2,2,0,0))
    plot(-10,-10,ylim=c(0,9), xlim=c(0,9),axes=F)
	  #mtext(c('$INP_dirs'),side=1,cex=0.4,adj=0)
	  #mtext(c('$params'),side=1,cex=0.4,adj=0)
    circle(x=3, y=6, r=3, col=rgb(1,0,0,.5), border=NA)
    circle(x=6, y=6, r=3, col=rgb(0,.5,.1,.5), border=NA)
    if(cMissing == F)
    {
       	circle(x=4.5, y=3, r=3, col=rgb(0,0,1,.5), border=NA)
       	text( x=c(1,8,4.5), y=c(6,6,0.8), labels, cex=1.5, col="gray90" )
       	text( x=c(2, 7, 4.5, 4.5, 3, 6, 4.5), y=c(7, 7, 2, 7, 4, 4, 5), 
        c(nA, nB, nC, nAB, nAC, nBC, nABC), cex=2)
	
 	      # return sectors, including intersections of two sets Aug2017
	      list(uniqueA,uniqueB,uniqueC,intersAB,intersAC,intersBC)
    }
    else
    {
       	text( x=c(1.9, 7.2), y=c(7.8, 7.8), labels, cex=1.5, col="gray90" )
       	text( x=c(2, 7, 4.5), y=c(6, 6, 6), 
        c(nA, nB, nAB), cex=2)
		
   	    # return sectors
	      list(uniqueA,uniqueB)
    }
}

input_files = read.table('$tmp_input_file',header=F)

set1 = read.table(toString(input_files[1,1]),sep="\n",colClasses="character")
set2 = read.table(toString(input_files[2,1]),sep="\n",colClasses="character")
labels = c(toString(input_files[1,2]),toString(input_files[2,2]))

if(nrow(input_files) == 6)
{
	set3 = read.table(toString(input_files[3,1]),sep="\n",colClasses="character")
	labels[3] <- toString(input_files[3,2])
	sectors = venndia(labels,set1[1]\$V1,set2[1]\$V1,set3[1]\$V1)
	# print venn sectors to files
  # unique
	if(length(sectors[1])>0){ lapply(sectors[1],write,toString(input_files[1,3]),append=T,ncolumns=1) }
	if(length(sectors[2])>0){ lapply(sectors[2],write,toString(input_files[2,3]),append=T,ncolumns=1) }
	if(length(sectors[3])>0){ lapply(sectors[3],write,toString(input_files[3,3]),append=T,ncolumns=1) }
  # intersections of two sets
  if(length(sectors[4])>0){ lapply(sectors[4],write,toString(input_files[4,3]),append=T,ncolumns=1) }
	if(length(sectors[5])>0){ lapply(sectors[5],write,toString(input_files[5,3]),append=T,ncolumns=1) }
	if(length(sectors[6])>0){ lapply(sectors[6],write,toString(input_files[6,3]),append=T,ncolumns=1) }
  
	
}else
{ 
	sectors = venndia(labels,set1[1]\$V1,set2[1]\$V1) 
	# print unique venn sectors to files
	if(length(sectors[1])>0){ lapply(sectors[1],write,toString(input_files[1,3]),append=T,ncolumns=1) }
  if(length(sectors[2])>0){ lapply(sectors[2],write,toString(input_files[2,3]),append=T,ncolumns=1) }
}	

q()
EOF
    close RSHELL;

    # 4) clean
    unlink(@venn,$tmp_input_file);

    # 5) check and print output
    if(-s $venn_file)
    {
      my $n_of_lines;
      print "\n# Venn diagram = $venn_file\n";
      foreach $k (@sector)
      {
        $n_of_lines = 0;
        if(-s $k > 2)
        {
          open(SECTOR,$k) || die "# $0 : cannot open $k\n";
          $n_of_lines += tr/\n/\n/ while sysread(SECTOR,$_,2 ** 16);
          close(SECTOR);
        }
        printf("# Venn region file: %s (%d)\n",$k,$n_of_lines);
      }
    }
    else
    {
      print "\n# ERROR: could not create a Venn diagram with these data, try setting \$RVERBOSE = 1 inside this script\n";
    }
  }
  else
  {
    print "\n# WARNING : this script requires the software R, available from http://www.r-project.org, \n".
      "# will not produce Venn diagram\n";
  }
}
else{ print "\n# WARNING: Venn diagrams are only available for 2 or 3 input cluster directories\n" }

