#!/usr/bin/perl -w
use strict;

# Parse whole-genome alignments (WGA) of A & B genomes/species 
# with the FASTA-like format produced by CGaln and produces 
# a table of 0-based, BED-like equivalent coordinates.
# Note: skips lowercase soft-masked bases.
#
# B Contreras-Moreira, R Sancho EEAD-CSIC, Unizar, 2017-2024

my $MAXMULTIBLOCKPOSITIONS = 0.25; # max ratio of mapped positions in other blocks
my $MAXMULTIPOSITIONS      = 0.05; # max ratio of coordinates with multiple positions in same block

my ($maxmultbk,$maxmult,$cgalnfile,$fastafileA,$fastafileB,$notCgaln);

if(!$ARGV[2]){ die "# usage: $0 <file.fasta.gz> <A fasta file> <B fasta file> [float MAXMULTIBLOCKPOSITIONS] [float MAXMULTIPOSITIONS] [boolean, not Cgaln]\n" }
else{ ($cgalnfile,$fastafileA,$fastafileB,$maxmultbk,$maxmult,$notCgaln) = @ARGV }

if(!defined($maxmultbk)) {
  $maxmultbk = $MAXMULTIBLOCKPOSITIONS;
}

if(!defined($maxmult)) {
  $maxmult = $MAXMULTIPOSITIONS;
}

if(!defined($notCgaln)) {
  $notCgaln = 0;
}

warn "# MAXMULTIPOSITIONS: $maxmult\n";
warn "# MAXMULTIBLOCKPOSITIONS: $maxmultbk\n";
warn "# WGA file: $cgalnfile\n";
warn "# A FASTA file: $fastafileA\n";
warn "# B FASTA file: $fastafileB\n";
warn "# not Cgaln = $notCgaln\n\n";

my ($strandA,$chrA,$chrB,$genomeid,$cumulscore);
my ($startA,$endA,$startB,$endB,$posname,$blockid);
my ($seqA,$seqB,$realposA,$realposB,$aligned_position);
my ($block,$length,$pos,$baseA,$baseB,$Aposname);
my (%blocks,%map,%sameA,@realnameA,@realnameB,$n_of_chrs);

## 1) read FASTA files to get real chr names
$n_of_chrs = 0;
open(AFASTA,"$fastafileA") || die "# cannot extract $fastafileA\n"; 
while(<AFASTA>) {
  if(/^>(\S+)/) {
    $n_of_chrs++;
    $realnameA[$n_of_chrs] = $1;
  }
}
close(AFASTA);
warn "# number of chrs in A FASTA file: $n_of_chrs\n";
 
$n_of_chrs = 0;
open(BFASTA,"$fastafileB") || die "# cannot extract $fastafileB\n";
while(<BFASTA>) { 
  if(/^>(\S+)/) { 
    $n_of_chrs++;
    $realnameB[$n_of_chrs] = $1;
  }
}
close(BFASTA);
warn "# number of chrs in B FASTA file: $n_of_chrs\n";


## 2) parse genome alignment blocks
open(CGALN,"zcat $cgalnfile |") || die "# cannot extract $cgalnfile\n";
while(<CGALN>) {
  # block
  #####{ (forward) genomeA-fasta1 genomeB-fasta1  Bl #43
  #####{ (reverse) genomeA-fasta1_revcom  genomeB-fasta1  Bl #103
  if(/^#####\{ \((\w+)\) genomeA-fasta(\d+)\S*\s+genomeB-fasta(\d+)\s+Bl #(\d+)/) {
    ($strandA,$chrA,$chrB,$block) = ($1,$2,$3,$4);
    ($seqA,$seqB) = ('','');
    $blockid = $strandA.'_'.$chrA.'_'.$chrB.'_'.$block;
    #print "$strandA,$chrA,$chrB,$block\n";

    #initialize block 
    $blocks{$blockid}{'cumulscore'} = 0;
    $blocks{$blockid}{'block_overlaps'} = 0;
    $blocks{$blockid}{'multiple'} = 0;
    $blocks{$blockid}{'unique'} = 0;

  } elsif(/^>([AB])_fst\d+[_revcom]*:(\d+)-(\d+):HSP number \d+:score \d+:score_cumulative (\d+)/) {
    #>A_fst1:18718865-18718886:HSP number 14:score 44:score_cumulative 246
    #GTGTTCTTAAATATATTAATTA
    #>B_fst1:15082265-15082286:HSP number 14:score 44:score_cumulative 246
    #GTGCTCTTAACTATATTAGTTA

    $genomeid = $1;
    $cumulscore = $4;
    if($genomeid eq 'A') { 
      ($startA,$endA) = ($2,$3); #print "$genomeid $startA,$endA $strandA $cumulscore\n";

    } elsif($genomeid eq 'B') { 
      ($startB,$endB) = ($2,$3); #print "$genomeid $startB,$endB\n" ;
    }
    
    # store block cumulative score, reported in the first alignment
    if($blocks{$blockid}{'cumulscore'} == 0) {  
      $blocks{$blockid}{'cumulscore'} = $cumulscore;
    }
  } elsif(/^([ACGTNX-]+)/i) {
    if($genomeid eq 'A') { 
      $seqA = $1; 
    } elsif($genomeid eq 'B') { 
      $seqB = $1; 
      push(@{$blocks{$blockid}{'alignments'}},[ $startA, $endA, $seqA, $startB, $endB, $seqB ]);
    }
  }
}
close(CGALN);
printf(STDERR "# total blocks: %d\n\n", scalar(keys(%blocks)));

### 3) sort blocks and filter out overlapping positions
foreach $blockid (sort {$blocks{$b}{'cumulscore'}<=>$blocks{$a}{'cumulscore'} ||
                        $a cmp $b # to put forward ahead of reverse
                        } keys(%blocks)) {
  #next if($blocks{$blockid}{'cumulscore'} > 10_000); # debugging

  #printf("%s\t%d\t%d\n",
  #  $blockid,$blocks{$blockid}{'cumulscore'},
  #  scalar(@{$blocks{$blockid}{'alignments'}}));

  ($strandA,$chrA,$chrB,$block) = split(/_/,$blockid);

  foreach my $align (@{$blocks{$blockid}{'alignments'}}) {
    ($startA,$endA,$seqA) = ($align->[0],$align->[1],$align->[2]);
    ($startB,$endB,$seqB) = ($align->[3],$align->[4],$align->[5]);
  
    my @seqA = split(//,$seqA);
    my @seqB = split(//,$seqB);
    $length = scalar(@seqA);

    $realposB = $startB;
    if($strandA eq 'forward')
    {  
      $realposA = $startA 

    } else {
      if($notCgaln == 0) { 
        $realposA = $startA-2; # bug in CGaln?
      } else { 
        $realposA = $startA-1 
      }
    }  

    for($pos=0;$pos<$length;$pos++) {
      $baseA = $seqA[$pos];
      $baseB = $seqB[$pos];
  
      # skip lowercase soft-masked bases
      if($baseA =~ m/[A-Z]/ && $baseB =~ m/[A-Z]/) {  
        $aligned_position = 
          sprintf("%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\t%d\t",
            $realnameA[$chrA],$realposA,$realposA+1,$baseA,
            $strandA eq 'forward' ? '+' : '-',
            $realnameB[$chrB],$realposB,$realposB+1,$baseB,
            $block);
      
        if($baseA ne $baseB) { 
          $aligned_position .= "SNP" 
        } else {
          $aligned_position .= "."
        }

        # NOTE: different coords in B.stacei/B.sylvaticum often correspond to the same coord
        $Aposname = $realnameA[$chrA].'_'.$realposA;
        $sameA{$Aposname}++;   

        #if($Aposname eq '3_10934410'){ warn "OJO: $aligned_position $sameA{$Aposname} $blockid\n" } # debug

        # NOTE: alignments within the same block ocasionally overlap in their ends
        # When this happens only the first position reported is stored 
        $posname = $realnameB[$chrB].'_'.$realposB;
        if(!$map{$posname}) {
          push(@{$blocks{$blockid}{'unique_positions'}}, $aligned_position);

          # remember this position is already mapped in this block
          $map{$posname} = $blockid;

        } elsif(defined($map{$posname}) && $blockid ne $map{$posname}) {
          $blocks{$blockid}{'block_overlaps'}++;
        }
        #elsif($map{$posname} && $map{$posname} ne $realnameA[$chrA].'_'.$realposA){
        #  # in case you want to print overlapping positions
        #  print "# position $posname has multiple synteny-based coordinates\n";
        #}
      }
       
      $realposB++;
      if($strandA eq 'forward'){ $realposA++ }
      else{ $realposA-- }
    }
  }
}

### 4) iterate over blocks and sort filtered mapped positions
my $valid_blocks = 0;
my $unique_positions = 0;

warn "# list of valid blocks:\n";

# headers
printf("# %s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        'chrA','posA','endA','baseA','strandA',
        'chrB','posB','endB','baseB',
        'block','SNP');

printf(STDERR "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        'blockid','cumulscore','alignments',
        'unique','multiple','block_overlaps',
        'ratio(unique)','ratio(block_overlaps)');

foreach $blockid (sort {$blocks{$b}{'cumulscore'}<=>$blocks{$a}{'cumulscore'} ||
                        $a cmp $b # to put forward ahead of reverse
                       } keys(%blocks)) {
  #next if($blocks{$blockid}{'cumulscore'} > 10_000); # debugging

  # skip blocks with no unique positions
  next if(!defined($blocks{$blockid}{'unique_positions'}));

  # skip blocks with too many positions mapped in other blocks
  my $multiblockratio = $blocks{$blockid}{'block_overlaps'}/scalar(@{$blocks{$blockid}{'unique_positions'}});
  next if($multiblockratio > $maxmultbk);

  # print final mapped positions
  my (@unique_positions);
  foreach $pos (@{$blocks{$blockid}{'unique_positions'}}) {
    ($chrA,$realposA,$baseA) = split(/\t/,$pos,3);
    $Aposname = $chrA.'_'.$realposA; 

    if($sameA{$Aposname} == 1) {
      push(@unique_positions,$pos);
      $blocks{$blockid}{'unique'}++;

    } else {
      $blocks{$blockid}{'multiple'}++;
    }
  }

  # print HQ positions and block stats
  if($blocks{$blockid}{'multiple'}/scalar(@{$blocks{$blockid}{'unique_positions'}}) < $maxmult) {
    foreach $pos (@unique_positions) {
      print "$pos\n";
    }

    # print block stats to STDERR 
    printf(STDERR "%s\t%d\t%d\t%d\t%d\t%d\t%1.3f\t%1.3f\n",
      $blockid,$blocks{$blockid}{'cumulscore'},
      scalar(@{$blocks{$blockid}{'alignments'}}),
      $blocks{$blockid}{'unique'},
      $blocks{$blockid}{'multiple'},
      $blocks{$blockid}{'block_overlaps'},
      $blocks{$blockid}{'unique'}/scalar(@{$blocks{$blockid}{'unique_positions'}}),
      $blocks{$blockid}{'block_overlaps'}/scalar(@{$blocks{$blockid}{'unique_positions'}})); 

    $unique_positions += $blocks{$blockid}{'unique'};
    $valid_blocks++;
  }    
}

printf(STDERR "# valid blocks: %d unique positions: %d\n", 
  $valid_blocks, $unique_positions);
