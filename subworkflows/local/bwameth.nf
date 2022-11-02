/*
 * bwameth subworkflow
 */
include { SAMTOOLS_STATS                                } from '../../modules/nf-core/samtools/stats/main'
include { SAMTOOLS_FLAGSTAT                             } from '../../modules/nf-core/samtools/flagstat/main'
include { SAMTOOLS_INDEX as SAMTOOLS_INDEX_ALIGNMENTS   } from '../../modules/nf-core/samtools/index/main'
include { SAMTOOLS_INDEX as SAMTOOLS_INDEX_DEDUPLICATED } from '../../modules/nf-core/samtools/index/main'
include { SAMTOOLS_SORT                                 } from '../../modules/nf-core/samtools/sort/main'
include { SAMTOOLS_FAIDX                                } from '../../modules/nf-core/samtools/faidx/main'
include { PICARD_MARKDUPLICATES                         } from '../../modules/nf-core/picard/markduplicates/main'
include { BWAMETH_INDEX                                 } from '../../modules/nf-core/bwameth/index/main'
include { BWAMETH_ALIGN                                 } from '../../modules/nf-core/bwameth/align/main'
include { METHYLDACKEL_EXTRACT                          } from '../../modules/nf-core/methyldackel/extract/main'
include { METHYLDACKEL_MBIAS                            } from '../../modules/nf-core/methyldackel/mbias/main'

workflow BWAMETH {
    take:
    reads  // channel: [ val(meta), [ reads ] ]

    main:
    /*
     * Generate bwameth index if not supplied
     */
    if (params.bwa_meth_index) {
        ch_bwameth_index = params.bwa_meth_index
    } else {
        ch_bwameth_index = BWAMETH_INDEX(params.fasta).out.index
    }

    /*
     * Generate fasta index if not supplied
     */
    if (params.fasta_index) {
        ch_fasta_index = params.fasta_index
    } else {
        ch_bwameth_index = SAMTOOLS_FAIDX([[:], params.fasta]).out.fai.map{ return(it[1])}
    }

    /*
     * Align with bwameth
     */
    BWAMETH_ALIGN (
        reads,
        ch_bwameth_index
    )

    /*
     * Sort raw output BAM
     */
    SAMTOOLS_SORT (BWAMETH_ALIGN.out.bam)

    /*
     * Run samtools index on alignment
     */
    SAMTOOLS_INDEX_ALIGNMENTS (SAMTOOLS_SORT.out.bam)

    /*
     * Run samtools flagstat and samtools stats
     */
    SAMTOOLS_FLAGSTAT( BWAMETH_ALIGN.out.bam.join(SAMTOOLS_INDEX_ALIGNMENTS.out.bai) )
    SAMTOOLS_STATS( BWAMETH_ALIGN.out.bam.join(SAMTOOLS_INDEX_ALIGNMENTS.out.bai), [] )

    if (params.skip_deduplication || params.rrbs) {
        alignments = SAMTOOLS_SORT.out.bam
        bam_index = SAMTOOLS_INDEX_ALIGNMENTS.out.bai
        picard_metrics = Channel.empty()
        picard_version = Channel.empty()
    } else {
        /*
        * Run Picard MarkDuplicates
        */
        PICARD_MARKDUPLICATES (
            SAMTOOLS_SORT.out.bam,
            params.fasta,
            ch_fasta_index
        )
        /*
         * Run samtools index on deduplicated alignment
        */
        SAMTOOLS_INDEX_DEDUPLICATED (PICARD_MARKDUPLICATES.out.bam)

        alignments = PICARD_MARKDUPLICATES.out.bam
        bam_index = SAMTOOLS_INDEX_DEDUPLICATED.out.bai
        picard_metrics = PICARD_MARKDUPLICATES.out.metrics
        picard_version = PICARD_MARKDUPLICATES.out.versions
    }


    /*
     * Extract per-base methylation and plot methylation bias
     */

    METHYLDACKEL_EXTRACT(
        alignments.join(bam_index),
        params.fasta,
        ch_fasta_index
    )
    METHYLDACKEL_MBIAS(
        alignments.join(bam_index),
        params.fasta,
        ch_fasta_index
    )

    if (!params.skip_multiqc) {
        /*
        * Collect MultiQC inputs
        */
        picard_metrics.collect{ it[1] }
            .mix(SAMTOOLS_FLAGSTAT.out.flagstat.collect{ it[1] })
            .mix(SAMTOOLS_STATS.out.stats.collect{ it[1] })
            .mix(METHYLDACKEL_EXTRACT.out.bedgraph.collect{ it[1] })
            .mix(METHYLDACKEL_MBIAS.out.txt.collect{ it[1] })
            .set{ ch_multiqc_files }
    } else {
        ch_multiqc_files = Channel.empty()
    }

    /*
     * Collect Software Versions
     */
    picard_version
        .mix(METHYLDACKEL_EXTRACT.out.versions)
        .mix(METHYLDACKEL_MBIAS.out.versions)
        .mix(SAMTOOLS_SORT.out.versions)
        .mix(BWAMETH_INDEX.out.versions)
        .set{ versions }

    emit:
    bam                  = SAMTOOLS_SORT.out.bam          // channel: [ val(meta), [ bam ] ] ## sorted, non-deduplicated (raw) BAM from aligner
    dedup                = alignments                     // channel: [ val(meta), [ bam ] ]  ## sorted, possibly deduplicated BAM
    mqc                  = ch_multiqc_files               // path: *{html,txt}
    versions                                              // path: *.version.txt
}
