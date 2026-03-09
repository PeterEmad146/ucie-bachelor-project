#include <stdio.h>

// 32 is plenty to test the O3 CPU cache bursts!
#define SIZE 128

// Global arrays bypass dynamic memory allocation overhead!
int A[SIZE][SIZE];
int B[SIZE][SIZE];
int C[SIZE][SIZE];

int main() {
    // 1. Initialize the arrays
    for(int i = 0; i < SIZE; i++) {
        for(int j = 0; j < SIZE; j++) {
            A[i][j] = i + j;
            B[i][j] = i - j;
            C[i][j] = 0;
        }
    }

    // 2. The heavy computational workload
    for (int i = 0; i < SIZE; ++i) {
        for (int j = 0; j < SIZE; ++j) {
            for (int k = 0; k < SIZE; ++k) {
                C[i][j] += A[j][k] * B[k][j];
            }
        }
    }

    printf("Bare-Metal GEMM Completed!\n");
    return 0;
}