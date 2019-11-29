import sys
import time
import os
from os import path
import pandas as pd
from glob import glob
import re
from threading import Lock
from itertools import zip_longest
from collections import OrderedDict, namedtuple

if not workflow.overwrite_configfiles:
    configfile: "config.yml"

WORKDIR = path.abspath(path.join(config["workdir_top"], config["pipeline"]))
workdir: WORKDIR
SNAKEDIR = path.dirname(workflow.snakefile)

include: "snakelib/utils.snake"

in_fastq = config["reads_fastq"]
if not path.isabs(in_fastq):
	in_fastq = path.join(SNAKEDIR, in_fastq)


class Node:
    def __init__(self, Id, File, Left, Right, Parent, Level):
        self.Id = Id
        self.File = File
        self.Left = Left
        self.Right = Right
        self.Parent = Parent
        self.Level = Level
        self.Done = False
    def __repr__(self):
        return "Node:{} Level: {} File: {} Done: {} Left: {} Right: {} Parent: {}".format(self.Id, self.Level, self.File, self.Done, self.Left.Id if self.Left is not None else None, self.Right.Id if self.Right is not None else None, self.Parent.Id if self.Parent is not None else None)

def grouper(n, iterable, fillvalue=None):
    "grouper(3, 'ABCDEFG', 'x') --> ABC DEF Gxx"
    args = [iter(iterable)] * n
    return zip_longest(fillvalue=fillvalue, *args)

def build_job_tree(batch_dir):
    batches = glob("{}/isONbatch_*.cer".format(batch_dir))
    batch_ids = [int(re.search('/isONbatch_(.*)\.cer$', x).group(1)) for x in batches]
    global LEVELS
    global JOB_TREE
    LEVELS = OrderedDict()
    LEVELS[0] = []
    for Id, bf in sorted(zip(batch_ids, batches), key=lambda x: x[0]):
        n = Node(Id, "clusters/isONcluster_{}.cer".format(Id), None, None, None, 0)
        n.Done = True
        JOB_TREE[Id] = n
        LEVELS[0].append(n)
    level = 0
    max_id = LEVELS[0][-1].Id
    while len(LEVELS[level]) != 1:
        next_level = level + 1
        LEVELS[next_level] = []
        for l, r in grouper(2, LEVELS[level]):
            if r is None:
                LEVELS[level].pop()
                l.Level += 1
                LEVELS[next_level].append(l)
                continue
            max_id += 1
            new_batch = "clusters/isONcluster_{}.cer".format(max_id)
            new_node = Node(max_id, new_batch, l, r, None, next_level)
            l.Parent = new_node
            r.Parent =  new_node
            LEVELS[next_level].append(new_node)
            JOB_TREE[max_id] = new_node
        level = next_level
    global ROOT
    ROOT = JOB_TREE[len(JOB_TREE)-1].Id
    print("Merge clustering job tree nodes:",file=sys.stderr)
    for n in JOB_TREE.values():
        print("\t{}".format(n),file=sys.stderr)


def generate_rules(levels, snk):
    init_template = """
rule cluster_job_%d:
    input:
        left = "sorted/batches/isONbatch_%d.cer",
    output: "clusters/isONcluster_%d.cer"
    shell: "isONclust2 cluster -x %s -v -Q -l %s -o %s"

    """
    template = """
rule cluster_job_%d:
    input:
        left = "clusters/isONcluster_%d.cer",
        right = "clusters/isONcluster_%d.cer",
    output: "clusters/isONcluster_%d.cer"
    shell: "isONclust2 cluster -x %s -v -Q -l %s -r %s -o %s"

    """
    fh = open(snk, "w")
    for nr, l in levels.items():
        for n in l:
            if nr == 0 or n.Left is None or n.Right is None:
                jr = init_template % (n.Id, n.Id, n.Id, config["cls_mode"], "{input.left}", "{output}")
                fh.write(jr)
            else:
                jr = template % (n.Id, n.Left.Id, n.Right.Id, n.Id, config["cls_mode"], "{input.left}", "{input.right}", "{output}")
                fh.write(jr)
    fh.flush()
    fh.close()

def count_fastq_bases(fname, size=128000000):
    fh = open(fname, "r")
    count = 0
    while True:
        b = fh.read(size)
        if not b:
            break
        count += b.count("A")
        count += b.count("T")
        count += b.count("G")
        count += b.count("C")
        count += b.count("U")
    fh.close()
    return count

nr_bases = count_fastq_bases(in_fastq)
if config['batch_size'] < 0:
    config['batch_size'] = int(nr_bases/1000/config["cores"])

print("Batch size is: {}".format(config['batch_size']))

init_cls_options = """ --batch-size {} --kmer-size {} --window-size {} --min-shared {} --min-qual {}\
                     --mapped-threshold {} --aligned-threshold {} --min-fraction {} --min-prob-no-hits {}"""
init_cls_options = init_cls_options.format(config["batch_size"], config["kmer_size"], config["window_size"], config["min_shared"], config["min_qual"], \
                    config["mapped_threshold"], config["aligned_threshold"], config["min_fraction"], config["min_prob_no_hits"])


shell("""
        rm -fr clusters sorted
        mkdir -p sorted; isONclust2 sort {} -v -o sorted {};
        mkdir -p clusters;
    """.format(init_cls_options, in_fastq))
JOB_TREE = OrderedDict()
LEVELS = None
ROOT = None

build_job_tree("sorted/batches")
generate_rules(LEVELS, "{}/job_rules.snk".format(SNAKEDIR))
FINAL_CLS = "clusters/isONcluster_{}.cer".format(ROOT)

include: "job_rules.snk"

rule all:
    input: FINAL_CLS
    output: directory("final_clusters")
    params:
    shell:
        """ isONclust2 dump -v -o {output} {input} """
