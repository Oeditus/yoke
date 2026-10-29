# Quantum Computing: Algorithms & Theoretical Foundations

> A dense technical reference on quantum algorithms, their speedups, assumptions, and the gap between promise and practice. Written for engineers and researchers who want the real story, not the press release.

---

## 0. TL;DR — The Honest Summary

Quantum computers are **not** "parallel classical computers." They offer provable speedups for **specific structured problems** — factoring, unstructured search (quadratically), quantum simulation, and certain algebraic/linear-algebra tasks — but *not* for general-purpose computing. The two dominant realities:

1. **Fault tolerance is the gate.** Nearly every exponential speedup (Shor, HHL, quantum chemistry, quantum linear algebra) requires **millions of physical qubits** running error correction at overheads of ~10³–10⁴ physical qubits per logical qubit. Current hardware is at ~10²–10³ *noisy* physical qubits with error rates ~10⁻³. The gap is 3–6 orders of magnitude.
2. **Dequantization is real.** Ewin Tang (2018) and successors showed that several celebrated "exponential quantum speedups" for **recommendation systems, low-rank linear algebra, and some sampling problems** can be matched classically in the *same input model*. Many "quantum ML advantage" claims collapsed under this scrutiny.

The durable wins are: **Shor's factoring** (exponential, but requires fault tolerance), **Grover's search** (quadratic, provably optimal), **quantum simulation** (the original Feynman motivation, exponential for many-body dynamics), and **amplitude estimation** (quadratic, with real near-term-adjacent variants). The rest is a mix of genuine theory and marketing.

---

## 1. Foundations

### 1.1 Qubits and State Space

A classical bit is in {0,1}. A **qubit** is a unit vector in ℂ²:

$$|\psi\rangle = \alpha|0\rangle + \beta|1\rangle, \quad |\alpha|^2 + |\beta|^2 = 1$$

An $n$-qubit system lives in the tensor product $(\mathbb{C}^2)^{\otimes n} \cong \mathbb{C}^{2^n}$ — **exponentially many amplitudes**. This is the source of quantum power *and* the source of the simulation bottleneck: writing down the state classically costs $2^n$ complex numbers.

### 1.2 Superposition

A superposition is a linear combination of basis states. Crucially, **you cannot read out the amplitudes**. Measurement collapses to one basis state with probability given by the Born rule. Superposition is *not* "trying all answers at once and reading them all" — it's a resource that must be *interfered* into a measurable signal.

### 1.3 Entanglement

A pure state is **entangled** if it cannot be written as a product $|\psi_A\rangle \otimes |\psi_B\rangle$. Example (Bell state): $\frac{1}{\sqrt2}(|00\rangle + |11\rangle)$. Entanglement is the resource behind Bell-inequality violations, quantum teleportation, and much of the computational advantage in simulation and communication. It is **not** by itself a computational speedup — entanglement without a clever algorithm does nothing.

### 1.4 Measurement

- **Computational basis measurement**: projects onto $|0\rangle/|1\rangle$, destroys superposition.
- **Partial measurement**: measuring a subset collapses the rest.
- **POVMs**: the most general measurement formalism (positive operator-valued measures).
- **The readout bottleneck**: an $n$-qubit state has $2^n$ amplitudes but yields only $n$ classical bits per measurement. Algorithms must *concentrate* the answer's probability amplitude so a few measurements suffice. This is why "quantum parallelism" is a myth: amplitude amplification (Grover) is the canonical way to extract one of $N$ answers in $O(\sqrt N)$, not $O(1)$.

### 1.5 Quantum Gates and Circuits

Gates are **unitary** matrices ($U^\dagger U = I$), hence reversible. A circuit is a sequence of gates on a register, read left-to-right.

| Gate | Matrix / action | Role |
|------|-----------------|------|
| $X$ (NOT) | $\begin{pmatrix}0&1\\1&0\end{pmatrix}$ | bit flip |
| $Z$ | $\begin{pmatrix}1&0\\0&-1\end{pmatrix}$ | phase flip |
| $H$ (Hadamard) | $\frac{1}{\sqrt2}\begin{pmatrix}1&1\\1&-1\end{pmatrix}$ | creates superposition |
| $S, T$ | phase gates ($\pi/2$, $\pi/4$) | phase manipulation; $T$ enables universality |
| CNOT | controlled-$X$ | entangling two-qubit gate |
| Toffoli (CCNOT) | controlled-controlled-$X$ | classical-universal, reversible |
| $R_z(\theta)$ | $e^{-i\theta Z/2}$ | rotation, used in variational ansätze |

**Universality**: a gate set is universal if it approximates any unitary to arbitrary accuracy. Standard results:
- $\{H, T, \text{CNOT}\}$ is **universal** for quantum computation (Solovay–Kitaev: overhead polylog in $1/\epsilon$).
- $\{$Toffoli, Hadamard$\}$ is universal.
- **Clifford gates** $\{H, S, \text{CNOT}\}$ alone are *not* universal — they are efficiently classically simulable (Gottesman–Knill). The non-Clifford **$T$ gate is the expensive resource** (magic states, distillation), a recurring practical cost.

**Circuit depth vs. width**: near-term devices are limited by *coherence time* (depth) and *connectivity* (topology), not just qubit count. A 1000-qubit device with depth 20 is far less useful than the number suggests.

---

## 2. The Algorithm Families

### 2.1 Shor's Factoring (and Discrete Log)

**Problem**: factor an $n$-bit integer $N$; equivalently find the period of $f(x) = a^x \bmod N$.

**Mechanism**: reduce factoring to **order finding**, solved by **Quantum Phase Estimation (QPE)** on the modular-exponentiation unitary. QPE uses the **Quantum Fourier Transform (QFT)**, implementable in $O(n^2)$ gates (vs. $O(n 2^n)$ classically).

**Speedup**: **Exponential**. Best known classical: sub-exponential (General Number Field Sieve, $L_N[1/3, \cdot]$). Quantum: $O(n^3)$ gates (with care, $O(n^2 \log n \log\log n)$ in refined analyses). Discrete log and elliptic-curve discrete log fall to the same machinery.

**Assumptions & caveats**:
- Requires **fault-tolerant** QPE — thousands of logical qubits, millions of physical qubits, hours-to-days of coherent runtime for RSA-2048.
- Resource estimates for RSA-2048: ~**20 million noisy physical qubits** (Gidney–Ekerå 2019, ~8 hours) down to ~**fewer with better codes**, but still far beyond current hardware.
- **Breaks RSA/ECC/Diffie–Hellman** — the reason for post-quantum cryptography (NIST PQC standards: Kyber/ML-KEM, Dilithium/ML-DSA, etc.).
- **Provably does not** imply $P = NP$ or solve NP-hard problems.

**Status**: theoretically settled, practically **not yet** — no fault-tolerant machine exists.

### 2.2 Grover's Search

**Problem**: find a marked item among $N$ unstructured items with an oracle.

**Mechanism**: amplitude amplification — $O(\sqrt N)$ oracle calls via repeated *oracle + diffusion* reflections (Grover iterate), rotating the state toward the target.

**Speedup**: **Quadratic** ($O(\sqrt N)$ vs $O(N)$). **Provably optimal** for unstructured search (Bennett–Bernstein–Brassard–Vazirani lower bound).

**Assumptions & caveats**:
- Quadratic speedups are **modest** and easily erased by constant-factor overheads (error correction, oracle cost).
- Applies to **unstructured** search; structured problems often have better classical algorithms.
- Cannot beat $2^{n/2}$ for brute-forcing a key — halves symmetric key security (AES-128 → ~64-bit quantum security), motivating AES-256.
- Grover on a *fault-tolerant* machine is real but the constant factors are brutal.

### 2.3 Quantum Simulation (Chemistry & Materials)

**The original Feynman motivation.** Simulating $n$ interacting quantum particles classically costs exponential resources; a quantum computer *is* a quantum system.

**Mechanism**: Hamiltonian simulation — Trotterization, qubitization, linear combinations of unitaries (LCU), quantum signal processing. Then extract eigenvalues (ground-state energy) via QPE or variational methods.

**Speedup**: **Exponential** for many-body dynamics and ground-state energy estimation (in system size), **polynomial** in some regimes vs. best classical (DMRG, coupled cluster, QMC).

**Assumptions & caveats**:
- The **most likely near-to-mid-term real application** (catalysis, battery materials, drug binding, FeMoco nitrogenase).
- Requires fault tolerance for the exponential claims; **classical heuristics (DMRG, coupled-cluster, tensor networks, QMC) are extremely strong** for many practically relevant systems (1D, low entanglement, sign-problem-free).
- The advantage is regime-dependent: strongly correlated, high-entanglement, sign-problematic systems are where quantum wins.
- **Input/output bottleneck**: preparing the initial state and reading out observables can dominate.

### 2.4 QAOA / VQE (Variational & Near-Term Heuristics)

**QAOA** (Quantum Approximate Optimization Algorithm) and **VQE** (Variational Quantum Eigensolver) are **hybrid** algorithms: a shallow parameterized quantum circuit, a classical optimizer tuning parameters.

- **QAOA**: targets combinatorial optimization (MaxCut etc.); depth-$p$ circuit; approximation ratio improves with $p$.
- **VQE**: targets ground-state energy; ansatz (e.g., UCCSD) + classical minimization.

**Speedup**: **None proven.** These are heuristics. No rigorous separation from classical methods is known, and **barren plateaus** (gradients vanish exponentially with qubit count) make them hard to train at scale.

**Assumptions & caveats**:
- Designed for **NISQ** (Noisy Intermediate-Scale Quantum) devices — no error correction.
- **Dequantization & classical shadows** often match them.
- Empirically, classical heuristics (Goemans–Williamson, simulated annealing, tensor networks) frequently beat small QAOA instances.
- **Hype alert**: many "quantum advantage" demos are on toy problems with classically solvable structure.

### 2.5 HHL and Quantum Linear Algebra

**HHL** (Harrow–Hassidim–Lloyd, 2009) solves $A\mathbf{x} = \mathbf{b}$ for a sparse, well-conditioned $A$ in **polylog time** in matrix dimension — *exponential* speedup in $n$ under strong conditions.

**Speedup**: **Exponential**, but with severe caveats.

**Assumptions & caveats (the "fine print")**:
- Requires **efficient state preparation** of $|b\rangle$ (often the real bottleneck).
- Requires **sparse, well-conditioned** $A$ (condition number $\kappa$ enters polynomially — $\text{poly}(\kappa)$).
- Output is a **quantum state** $|x\rangle$, not a classical vector — you get **one scalar readout** (e.g., $\langle x|M|x\rangle$) per run, not $\mathbf{x}$.
- **Dequantization**: Tang (2018) showed classical algorithms achieve comparable performance for **low-rank** linear algebra and recommendation systems under the same input assumptions — the "quantum advantage" evaporates in those regimes.
- Practical HHL on real data is **not demonstrated**.

### 2.6 Quantum Walks

Discrete- and continuous-time quantum walks are the quantum analog of random walks.

**Speedup**: **Quadratic** for spatial search (walk-based Grover), **exponential** for some graph/glued-tree problems (e.g., element distinctness $O(N^{2/3})$ via Ambainis' walk — a *genuine* polynomial speedup over $O(N)$).

**Assumptions & caveats**: Requires coherent walk evolution; oracle/input model matters; many walk speedups are polynomial, not exponential.

### 2.7 Amplitude Amplification & Estimation

- **Amplitude amplification**: generalizes Grover to arbitrary success probabilities — quadratic speedup for any algorithm with a checkable success flag (Brassard et al.).
- **Amplitude estimation**: estimates the amplitude $\sqrt{p}$ to precision $\epsilon$ in $O(1/\epsilon)$ queries — **quadratic** over classical Monte Carlo's $O(1/\epsilon^2)$. This is the engine behind **quantum Monte Carlo / finance** claims.
- **Caveats**: requires coherent oracle access; output is a scalar estimate; error correction or good NISQ approximations (e.g., iterative/MLAE) needed.

### 2.8 Quantum Machine Learning (and its Realistic Limits)

**Claimed**: exponential speedups for recommendation, clustering, linear systems, kernels, PCA, Boltzmann sampling.

**Reality check**:
- **Dequantization** (Tang 2018, and follow-ups on PCA, regression, recommendation, low-rank matrix inversion) showed many of these are **classically matchable** under the same input model.
- **Input bottleneck**: loading classical data into a quantum state ($|b\rangle$) can cost as much as the computation.
- **Output bottleneck**: extracting a full classical model/vector is exponential.
- **Barren plateaus** and trainability issues plague variational QML.
- **Quantum kernels** can be classically simulated in many regimes.
- Genuine potential niches: quantum data (states from nature), inherently quantum features, and specific sampling tasks.

**Verdict**: QML is the area with the **largest hype-to-substance gap**. Treat "quantum advantage in ML" claims as unproven until a dequantization-resistant, input/output-economical, fault-tolerant demonstration exists.

---

## 3. Complexity Classes

| Class | Definition | Relation |
|-------|-----------|----------|
| **BQP** | Bounded-error quantum poly-time (uniform circuits) | $P \subseteq BQP \subseteq PSPACE$; $BQP \not\supseteq NP$ believed; contains factoring (Shor) |
| **QMA** | Quantum analog of NP (quantum witness, quantum verifier) | $NP \subseteq QMA$; QMA-complete problems (Local Hamiltonian) |
| **QMA(2)** | QMA with two unentangled witnesses | Contains QMA; QMA(2) vs QMA open |
| **BPP** | Classical bounded-error poly-time | $BPP \subseteq BQP$ |
| **NP** | Nondeterministic poly-time | $BQP$ vs $NP$ open; factoring believed **not** NP-complete |

**Key facts**:
- **Factoring ∈ BQP** but **not known to be NP-complete** — quantum computers do **not** solve NP-hard problems (unless NP ⊆ BQP, believed false).
- **BQP vs NP**: widely believed $NP \not\subseteq BQP$; Grover's $\sqrt N$ is the best generic unstructured speedup, and it does not collapse NP.
- **QMA-complete**: the Local Hamiltonian problem (ground-state energy of a local Hamiltonian to inverse-polynomial precision) — the "quantum NP-complete."
- **$P$ vs $NP$**: quantum computing is **orthogonal** — it does not resolve this.

---

## 4. Summary Table: Algorithms vs. Speedups vs. Status

| Algorithm / Family | Problem | Speedup | Key Assumptions / Caveats | Practical Status |
|---|---|---|---|---|
| **Shor** | Integer factoring, discrete log | **Exponential** | Fault tolerance; ~millions of physical qubits for RSA-2048; QPE + QFT | Theory settled; **not yet practical** |
| **Grover** | Unstructured search | **Quadratic** ($O(\sqrt N)$) | Oracle access; provably optimal; constant-factor overhead | Fault-tolerant only; halves symmetric key security |
| **Quantum simulation** | Many-body dynamics, chemistry, materials | **Exponential** (system size) | Fault tolerance for exponential claims; strong classical heuristics (DMRG, QMC) in many regimes | **Most promising real application**; early demos |
| **QAOA** | Combinatorial optimization | **None proven** (heuristic) | NISQ; barren plateaus; classical heuristics often win | Experimental; toy problems |
| **VQE** | Ground-state energy | **None proven** (heuristic) | Ansatz quality; trainability; noise | Experimental; chemistry demos |
| **HHL** | Linear systems $Ax=b$ | **Exponential** (in $n$) | Sparse, well-conditioned $A$; state prep; quantum output only; **dequantized** for low-rank | Not demonstrated on real data |
| **Quantum walks** | Graph search, element distinctness | **Quadratic** to **polynomial** (e.g., $O(N^{2/3})$) | Coherent walk; oracle model | Theory; some experiments |
| **Amplitude estimation** | Monte Carlo, finance | **Quadratic** ($O(1/\epsilon)$ vs $O(1/\epsilon^2)$) | Coherent oracle; scalar output; error correction or NISQ variants | Early NISQ variants (MLAE) |
| **QML** | Recommendation, clustering, kernels, PCA | **Claimed exponential**, mostly **dequantized** | Input/output bottlenecks; barren plateaus; classical simulation | **Largest hype gap**; unproven |
| **Quantum kernels** | Classification | **Claimed**, often classically simulable | Data loading; kernel evaluation cost | Unproven |

---

## 5. Hype vs. Reality

**What is real (durable theory):**
- Shor's exponential factoring speedup — *given fault tolerance*.
- Grover's quadratic search — *provably optimal*.
- Quantum simulation of quantum systems — the original, most defensible motivation.
- Amplitude estimation's quadratic Monte Carlo speedup.
- Complexity separations (BQP contains factoring; QMA-complete Local Hamiltonian).

**What is oversold:**
- "Quantum computers will solve NP-hard problems" — **false** (no evidence NP ⊆ BQP).
- "Quantum parallelism tries all answers at once" — **false** (measurement collapses; amplification is needed).
- "Quantum ML will revolutionize AI" — **mostly dequantized**; input/output bottlenecks dominate.
- "We'll have useful quantum computers in 2–3 years" — the fault-tolerance gap is **3–6 orders of magnitude** in qubit count and error rate.
- "Qubit count is the metric" — **depth, connectivity, and error rate** matter more.

**The honest bottom line:**
- **Near-term (NISQ)**: narrow, noisy, heuristic experiments; quantum simulation and some optimization/chemistry toy problems; no proven advantage at scale.
- **Mid-term (early fault tolerance)**: quantum simulation of chemistry/materials, possibly cryptography-adjacent tasks.
- **Long-term (full fault tolerance)**: Shor, HHL, exponential simulation — *if* error correction scales as hoped.

The single biggest open engineering problem is **quantum error correction at scale**: surface codes need ~10³–10⁴ physical qubits per logical qubit, and logical error rates must be driven far below physical ones. Until that is solved, exponential-speedup algorithms remain theoretical.

---

## 6. Further Reading

- Nielsen & Chuang, *Quantum Computation and Quantum Information* (the standard text).
- Shor (1994/1997), "Polynomial-Time Algorithms for Prime Factorization and Discrete Logarithms."
- Grover (1996), "A Fast Quantum Mechanical Algorithm for Database Search."
- Harrow, Hassidim, Lloyd (2009), "Quantum Algorithm for Linear Systems of Equations."
- Tang (2018), "A quantum-inspired classical algorithm for recommendation systems."
- Gidney & Ekerå (2019/2021), "How to factor 2048 bit RSA integers in 8 hours using 20 million noisy qubits."
- Farhi, Goldstone, Gutmann (2014), "A Quantum Approximate Optimization Algorithm."
- Peruzzo et al. (2014), "A variational eigenvalue solver on a photonic quantum processor."
- Ambainis (2004), "Quantum walk algorithm for element distinctness."
- Preskill (2018), "Quantum Computing in the NISQ era and beyond."
