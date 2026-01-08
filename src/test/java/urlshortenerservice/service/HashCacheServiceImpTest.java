package java.urlshortenerservice.service;

import java.urlshortenerservice.config.RetryExecutor;
import java.urlshortenerservice.repository.HashRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import java.util.List;
import java.util.concurrent.ExecutorService;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class HashCacheServiceImpTest {

    @Mock
    private HashRepository hashRepository;

    @Mock
    private HashGenerator hashGenerator;

    @Mock
    private Base62Encoder base62Encoder;

    @Mock
    private ExecutorService executorService;

    @Mock
    private RetryExecutor retryExecutor;

    private HashCacheServiceImp hashCache;

    @BeforeEach
    void setUp() {
        doAnswer(invocation -> {
            Runnable task = invocation.getArgument(0);
            task.run();
            return null;
        }).when(executorService).submit(any(Runnable.class));
        
        doAnswer(invocation -> {
            java.util.function.Supplier<?> supplier = invocation.getArgument(0);
            return supplier.get();
        }).when(retryExecutor).execute(any(java.util.function.Supplier.class));
        
        hashCache = new HashCacheServiceImp(
                hashRepository,
                hashGenerator,
                base62Encoder,
                executorService,
                retryExecutor,
                100,
                20
        );
    }

    @Test
    void getHash_WhenCacheHasHashes_ShouldReturnHash() {
        when(hashRepository.getHashBatch()).thenReturn(List.of("hash1", "hash2", "hash3"));
        
        hashCache.initialize();
        
        String hash = hashCache.getHash();
        
        assertThat(hash).isNotNull();
        assertThat(hashCache.size()).isGreaterThan(0);
    }

    @Test
    void getHash_WhenCacheEmpty_ShouldUseFallback() {
        when(hashRepository.getHashBatch()).thenReturn(List.of("fallbackHash"));
        
        String hash = hashCache.getHash();
        
        assertThat(hash).isNotNull();
        verify(hashRepository, atLeastOnce()).getHashBatch();
    }

    @Test
    void getHash_WhenFallbackFails_ShouldGenerateHash() {
        when(hashRepository.getHashBatch()).thenReturn(List.of());
        when(hashRepository.getUniqueNumbers(1)).thenReturn(List.of(1L));
        when(base62Encoder.encode(1L)).thenReturn("generatedHash");
        
        String hash = hashCache.getHash();
        
        assertThat(hash).isNotNull();
        verify(hashRepository).save(any());
    }

    @Test
    void size_ShouldReturnCurrentCacheSize() {
        when(hashRepository.getHashBatch()).thenReturn(List.of("hash1", "hash2"));
        
        hashCache.initialize();
        int size = hashCache.size();
        
        assertThat(size).isGreaterThan(0);
    }
}

