#include <iostream>
#include <vector>

// 128x128 matrix generates thousands of memory requests
#define SIZE 32

int main() {

    std::cout << "Starting AI Matrix Multiplication Workload (" << SIZE << "x" << SIZE << ")...\n";

    // Allocate three large contiguous memory blocks
    std::vector<std::vector<int>> A(SIZE, std::vector<int>(SIZE, 2));
    std::vector<std::vector<int>> B(SIZE, std::vector<int>(SIZE, 3));
    std::vector<std::vector<int>> C(SIZE, std::vector<int>(SIZE, 0));

    // Heavy CPU crunching: Generates massive, sustained memory traffic
    for (int i = 0; i < SIZE; ++i) {
        for (int j = 0; j < SIZE; ++j) {
            for (int k = 0; k < SIZE; ++k) {
                C[i][j] += A[i][k] * B[k][j];
            }
        }
    }

    // Quick verification check
    if (C[0][0] == SIZE * 6) {
        std::cout << "GEMM Workload Completed successfully!\n";
    }

    return 0;
}