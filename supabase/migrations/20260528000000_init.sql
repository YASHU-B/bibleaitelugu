-- Bible AI Telugu — Supabase Database Migration
-- Enabled extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Profiles Table (Synced automatically with Supabase Auth users)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT,
    email TEXT,
    avatar_url TEXT,
    role TEXT DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    is_premium BOOLEAN DEFAULT FALSE,
    favorite_language TEXT DEFAULT 'te',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to profiles" ON public.profiles
    FOR SELECT USING (true);

CREATE POLICY "Allow individual update of own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- Trigger to automatically create a profile when a new auth user is created
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, name, email, avatar_url, role, is_premium, favorite_language)
    VALUES (
        new.id,
        coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
        new.email,
        coalesce(new.raw_user_meta_data->>'avatar_url', ''),
        coalesce(new.raw_user_meta_data->>'role', 'user'),
        false,
        'te'
    );
    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM public.profiles
        WHERE id = auth.uid()
          AND role = 'admin'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- 2. Books Table
CREATE TABLE IF NOT EXISTS public.books (
    id INT PRIMARY KEY,
    name_en TEXT NOT NULL,
    name_te TEXT NOT NULL,
    testament TEXT CHECK (testament IN ('Old', 'New')) NOT NULL,
    book_order INT UNIQUE NOT NULL
);

ALTER TABLE public.books ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to books" ON public.books
    FOR SELECT USING (true);


-- 3. Verses Table
CREATE TABLE IF NOT EXISTS public.verses (
    id SERIAL PRIMARY KEY,
    book_id INT REFERENCES public.books(id) ON DELETE CASCADE NOT NULL,
    chapter INT NOT NULL,
    verse INT NOT NULL,
    text_en TEXT NOT NULL,
    text_te TEXT NOT NULL,
    CONSTRAINT unique_verse UNIQUE (book_id, chapter, verse)
);

ALTER TABLE public.verses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to verses" ON public.verses
    FOR SELECT USING (true);

-- Indexes for lightning fast Bible Reader queries and search
CREATE INDEX IF NOT EXISTS idx_verses_lookup ON public.verses(book_id, chapter);
CREATE INDEX IF NOT EXISTS idx_verses_search_en ON public.verses USING gin(to_tsvector('english', text_en));


-- 4. Bookmarks Table
CREATE TABLE IF NOT EXISTS public.bookmarks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    book_id INT REFERENCES public.books(id) ON DELETE CASCADE NOT NULL,
    chapter INT NOT NULL,
    verse INT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT unique_bookmark UNIQUE (user_id, book_id, chapter, verse)
);

ALTER TABLE public.bookmarks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow users to manage their own bookmarks" ON public.bookmarks
    FOR ALL USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_bookmarks_user ON public.bookmarks(user_id);


-- 5. Highlights Table
CREATE TABLE IF NOT EXISTS public.highlights (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    book_id INT REFERENCES public.books(id) ON DELETE CASCADE NOT NULL,
    chapter INT NOT NULL,
    verse INT NOT NULL,
    color_hex TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT unique_highlight UNIQUE (user_id, book_id, chapter, verse)
);

ALTER TABLE public.highlights ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow users to manage their own highlights" ON public.highlights
    FOR ALL USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_highlights_user ON public.highlights(user_id);


-- 6. Devotionals Table
CREATE TABLE IF NOT EXISTS public.devotionals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_en TEXT NOT NULL,
    title_te TEXT NOT NULL,
    content_en TEXT NOT NULL,
    content_te TEXT NOT NULL,
    verse_reference TEXT NOT NULL,
    image_url TEXT,
    active_date DATE DEFAULT CURRENT_DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.devotionals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to devotionals" ON public.devotionals
    FOR SELECT USING (true);

CREATE POLICY "Allow administrators to manage devotionals" ON public.devotionals
    FOR ALL USING (public.is_admin())
    WITH CHECK (public.is_admin());

CREATE TABLE IF NOT EXISTS public.notification_broadcasts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.notification_broadcasts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow administrators to manage notification broadcasts" ON public.notification_broadcasts
    FOR ALL USING (public.is_admin())
    WITH CHECK (public.is_admin());


-- 7. Prayers Table (Private / Public Prayers written by users)
CREATE TABLE IF NOT EXISTS public.prayers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    is_public BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.prayers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow owners to manage all own prayers" ON public.prayers
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "Allow public read access to public prayers" ON public.prayers
    FOR SELECT USING (is_public = true);

CREATE INDEX IF NOT EXISTS idx_prayers_user ON public.prayers(user_id);


-- 8. Prayer Requests Table (Shared Community Wall)
CREATE TABLE IF NOT EXISTS public.prayer_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    pray_count INT DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.prayer_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to prayer requests" ON public.prayer_requests
    FOR SELECT USING (true);

CREATE POLICY "Allow authenticated users to create prayer requests" ON public.prayer_requests
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Allow owners to update their prayer requests" ON public.prayer_requests
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Allow owners to delete their prayer requests" ON public.prayer_requests
    FOR DELETE USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.increment_prayer_count(request_id UUID, delta INT DEFAULT 1)
RETURNS VOID AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    UPDATE public.prayer_requests
    SET pray_count = GREATEST(0, pray_count + delta)
    WHERE id = request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- 9. Comments Table (Threaded comments on Devotionals & Prayer Requests)
CREATE TABLE IF NOT EXISTS public.comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    parent_id UUID NOT NULL, -- references devotionals or prayer_requests
    parent_type TEXT CHECK (parent_type IN ('devotional', 'prayer_request')) NOT NULL,
    user_name TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read access to comments" ON public.comments
    FOR SELECT USING (true);

CREATE POLICY "Allow authenticated users to insert comments" ON public.comments
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Allow owners to update their comments" ON public.comments
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Allow owners to delete their comments" ON public.comments
    FOR DELETE USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_comments_parent ON public.comments(parent_id);
