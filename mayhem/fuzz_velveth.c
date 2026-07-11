/*
 * mayhem/fuzz_velveth.c — libFuzzer harness for velvet's sequence-file parser.
 *
 * The original Mayhem target ran the full `velveth` driver against a fuzzed
 * sequence file (`velveth <outdir> 21 -fasta @@`). That driver does heavy,
 * stateful filesystem work on a FIXED output directory per exec
 * (opendir/mkdir/remove + an APPENDING `<outdir>/Log`, plus the splay-table
 * hashing), which Mayhem could not clear between the many executions it drives
 * with the same command — so even the trivial default test case (a buffer of
 * 'A's) tripped Mayhem's per-exec timeout.
 *
 * This harness fuzzes the EXACT parsing surface velveth exercises — the kseq.h
 * sequence reader used by readFastXFile() in src/readSet.c — directly and
 * in-process, with NO output directory, NO hashing, and NO global state. Each
 * exec is microseconds, so the default test case and the seeds complete well
 * under the timeout while the FASTA/FASTQ parser (the actual attack surface)
 * is still driven byte-for-byte.
 *
 * We instantiate kseq over an in-memory buffer (the fuzz input) using a custom
 * read callback, exactly mirroring velvet's `while (kseq_read(seq) >= 0)` loop.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "../src/kseq.h"

/* In-memory "file" the kseq reader pulls bytes from. */
typedef struct {
	const uint8_t *data;
	size_t len;
	size_t pos;
} membuf_t;

/* kseq read callback: copy up to `size` bytes out of the in-memory buffer.
 * Signature matches what KSEQ_INIT expects: (type_t f, void *buf, size_t size). */
static size_t membuf_read(membuf_t *m, void *buf, size_t size)
{
	size_t remaining = m->len - m->pos;
	size_t n = size < remaining ? size : remaining;
	if (n)
		memcpy(buf, m->data + m->pos, n);
	m->pos += n;
	return n;
}

/* Generate kseq_init / kseq_read / kseq_destroy over membuf_t. This is the
 * same kseq.h instantiation pattern velvet uses (KSEQ_INIT(FileGZOrAuto, ...)
 * in src/readSet.c), so the parser code under test is identical. */
KSEQ_INIT(membuf_t *, membuf_read)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	membuf_t m = { data, size, 0 };
	kseq_t *seq = kseq_init(&m);

	/* Drive the parser to completion, mirroring readFastXFile()'s loop.
	 * Touch every parsed field so the optimizer can't elide the work and so
	 * ASan/UBSan see any out-of-bounds / overflow in the record parsing. */
	volatile size_t sink = 0;
	while (kseq_read(seq) >= 0) {
		if (seq->name.s) sink += seq->name.l;
		if (seq->comment.s) sink += seq->comment.l;
		if (seq->seq.s) sink += seq->seq.l;
		if (seq->qual.s) sink += seq->qual.l;
	}
	(void)sink;

	kseq_destroy(seq);
	return 0;
}
