package java.urlshortenerservice.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

@Getter
@AllArgsConstructor
public class UrlWithCacheInfo {
    private final String url;
    private final boolean fromCache;
}

