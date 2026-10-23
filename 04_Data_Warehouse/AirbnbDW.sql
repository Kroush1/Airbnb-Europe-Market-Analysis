
/* =====================================================================
   1. DATABASE AND TABLES
   ===================================================================== */
IF DB_ID('AirbnbDW') IS NULL
    CREATE DATABASE AirbnbDW;
GO
USE AirbnbDW;
GO

IF OBJECT_ID('dbo.dim_city', 'U') IS NULL
CREATE TABLE dim_city (
    city_id   INT PRIMARY KEY,
    city      NVARCHAR(50) NOT NULL,
    country   NVARCHAR(50) NOT NULL
);

IF OBJECT_ID('dbo.dim_host_segment', 'U') IS NULL
CREATE TABLE dim_host_segment (
    host_segment_id   INT IDENTITY(1,1) PRIMARY KEY,
    host_segment      NVARCHAR(50) NOT NULL,
    is_superhost      BIT NOT NULL,
    is_guest_favorite BIT NOT NULL
);

IF OBJECT_ID('dbo.dim_price_tier', 'U') IS NULL
CREATE TABLE dim_price_tier (
    price_tier_id INT IDENTITY(1,1) PRIMARY KEY,
    price_tier    NVARCHAR(20) NOT NULL
);

IF OBJECT_ID('dbo.dim_listing', 'U') IS NULL
CREATE TABLE dim_listing (
    listing_id   BIGINT PRIMARY KEY,
    listing_name NVARCHAR(300) NOT NULL,
    url          NVARCHAR(600) NOT NULL
);

IF OBJECT_ID('dbo.fact_listing', 'U') IS NULL
CREATE TABLE fact_listing (
    listing_id               BIGINT PRIMARY KEY REFERENCES dim_listing(listing_id),
    city_id                  INT NOT NULL REFERENCES dim_city(city_id),
    host_segment_id          INT NOT NULL REFERENCES dim_host_segment(host_segment_id),
    price_tier_id            INT NOT NULL REFERENCES dim_price_tier(price_tier_id),
    price_total_usd          DECIMAL(10,2) NOT NULL,   
    price_per_night_usd      DECIMAL(10,2) NOT NULL,  
    rating                   DECIMAL(3,2) NULL,        
    reviews                  INT NOT NULL,
    price_vs_city_median_pct DECIMAL(6,1) NULL,
    has_rating               BIT NOT NULL
);
GO


/* =====================================================================
   2. VIEW: all tables joined in one place (for analysis and Power BI)
   ===================================================================== */
CREATE OR ALTER VIEW vw_listings AS
SELECT f.listing_id,
       l.listing_name,
       l.url,
       c.city,
       c.country,
       h.host_segment,
       h.is_superhost,
       h.is_guest_favorite,
       p.price_tier,
       f.price_total_usd,
       f.price_per_night_usd,
       f.rating,
       f.reviews,
       f.price_vs_city_median_pct,
       f.has_rating
FROM fact_listing f
JOIN dim_listing l       ON f.listing_id = l.listing_id
JOIN dim_city c          ON f.city_id = c.city_id
JOIN dim_host_segment h  ON f.host_segment_id = h.host_segment_id
JOIN dim_price_tier p    ON f.price_tier_id = p.price_tier_id;
GO


/* =====================================================================
   3. VALIDATION (run after loading)
   ===================================================================== */
SELECT 'dim_city' AS table_name, COUNT(*) AS rows_count FROM dim_city
UNION ALL SELECT 'dim_host_segment', COUNT(*) FROM dim_host_segment
UNION ALL SELECT 'dim_price_tier',   COUNT(*) FROM dim_price_tier
UNION ALL SELECT 'dim_listing',      COUNT(*) FROM dim_listing
UNION ALL SELECT 'fact_listing',     COUNT(*) FROM fact_listing
UNION ALL SELECT 'fact_listing (NULL rating)', COUNT(*) FROM fact_listing WHERE rating IS NULL;

-- Listings, average price, rating and superhosts per city (should sum to 636)
SELECT c.city,
       COUNT(*) AS listings,
       CAST(AVG(f.price_per_night_usd) AS DECIMAL(10,2)) AS avg_price_per_night,
       CAST(AVG(f.rating) AS DECIMAL(4,2))               AS avg_rating,
       SUM(CAST(h.is_superhost AS INT))                  AS superhosts
FROM fact_listing f
JOIN dim_city c          ON f.city_id = c.city_id
JOIN dim_host_segment h  ON f.host_segment_id = h.host_segment_id
GROUP BY c.city
ORDER BY avg_price_per_night DESC;


/* =====================================================================
   4. ANALYSIS QUERIES
   ===================================================================== */

-- Q1: Which cities are the most and least expensive? (median price per night)
WITH m AS (
    SELECT DISTINCT city, country,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_per_night_usd)
               OVER (PARTITION BY city) AS med
    FROM vw_listings
)
SELECT RANK() OVER (ORDER BY med DESC) AS price_rank,
       city, country,
       CAST(med AS DECIMAL(10,2)) AS median_price_per_night
FROM m
ORDER BY price_rank;


-- Q2: Do Superhosts charge more? (compared inside each city)
SELECT city,
       CAST(AVG(CASE WHEN is_superhost = 1 THEN price_per_night_usd END) AS DECIMAL(10,2)) AS avg_price_superhost,
       CAST(AVG(CASE WHEN is_superhost = 0 THEN price_per_night_usd END) AS DECIMAL(10,2)) AS avg_price_non_superhost,
       CAST(100.0 * (AVG(CASE WHEN is_superhost = 1 THEN price_per_night_usd END)
             / NULLIF(AVG(CASE WHEN is_superhost = 0 THEN price_per_night_usd END), 0) - 1) AS DECIMAL(6,1)) AS superhost_premium_pct
FROM vw_listings
GROUP BY city
ORDER BY superhost_premium_pct DESC;


-- Q3: Cheapest well-reviewed listing in each city (rating >= 4.8, 20+ reviews)
WITH ranked AS (
    SELECT city, listing_name, price_per_night_usd, rating, reviews, url,
           ROW_NUMBER() OVER (PARTITION BY city ORDER BY price_per_night_usd) AS rn
    FROM vw_listings
    WHERE rating >= 4.8 AND reviews >= 20
)
SELECT city, listing_name,
       CAST(price_per_night_usd AS DECIMAL(10,2)) AS price_per_night,
       rating, reviews, url
FROM ranked
WHERE rn = 1
ORDER BY price_per_night;


-- Q4: Is Guest Favorite linked to higher price, rating and reviews?
SELECT CASE WHEN is_guest_favorite = 1 THEN 'Guest Favorite' ELSE 'Not Guest Favorite' END AS status,
       COUNT(*) AS listings,
       CAST(AVG(price_per_night_usd) AS DECIMAL(10,2)) AS avg_price_per_night,
       CAST(AVG(rating) AS DECIMAL(4,2)) AS avg_rating,
       CAST(AVG(CAST(reviews AS FLOAT)) AS DECIMAL(10,1)) AS avg_reviews
FROM vw_listings
GROUP BY is_guest_favorite;


-- Q5: Do more expensive tiers get better ratings or more reviews?
SELECT price_tier,
       COUNT(*) AS listings,
       CAST(MIN(price_per_night_usd) AS DECIMAL(10,2)) AS min_price,
       CAST(MAX(price_per_night_usd) AS DECIMAL(10,2)) AS max_price,
       CAST(AVG(rating) AS DECIMAL(4,2)) AS avg_rating,
       CAST(AVG(CAST(reviews AS FLOAT)) AS DECIMAL(10,1)) AS avg_reviews
FROM vw_listings
GROUP BY price_tier
ORDER BY MIN(price_per_night_usd);


-- Q6: Share of unrated listings, Superhosts and Guest Favorites per city
SELECT city,
       COUNT(*) AS listings,
       CAST(100.0 * SUM(CASE WHEN has_rating = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS unrated_pct,
       CAST(100.0 * SUM(CAST(is_superhost AS INT)) / COUNT(*) AS DECIMAL(5,1)) AS superhost_pct,
       CAST(100.0 * SUM(CAST(is_guest_favorite AS INT)) / COUNT(*) AS DECIMAL(5,1)) AS guest_favorite_pct
FROM vw_listings
GROUP BY city
ORDER BY unrated_pct DESC;
