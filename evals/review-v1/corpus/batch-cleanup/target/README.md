# Review exercise

publish stages a batch of uploads and commits only when every stage succeeds. Failed batches must leave no staged objects behind. stage can settle in any order; remove accepts the ID returned by stage. Storage cleanup succeeds in this exercise.
