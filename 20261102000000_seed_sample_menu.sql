insert into public.menu_items (name, category, price, image_url, description)
select
    sample.name,
    sample.category,
    sample.price,
    sample.image_url,
    sample.description
from (
    values
        (
            'Chicken Dum Biryani',
            'Biryani & Rice',
            320,
            'https://images.unsplash.com/photo-1563379091339-03b21ab4a4f8?w=800&q=80',
            'Aromatic basmati rice layered with spiced chicken and slow-cooked dum.'
        ),
        (
            'Paneer Biryani',
            'Biryani & Rice',
            280,
            'https://images.unsplash.com/photo-1589302168068-967d63d6767d?w=800&q=80',
            'Fragrant basmati rice cooked with paneer, herbs, and warm spices.'
        ),
        (
            'Paneer Tikka',
            'Starters & Tandoor',
            260,
            'https://images.unsplash.com/photo-1599487488170-d11ec9c172f0?w=800&q=80',
            'Char-grilled paneer marinated with yogurt and tandoori spices.'
        ),
        (
            'Chicken 65',
            'Starters & Tandoor',
            240,
            'https://images.unsplash.com/photo-1610057099443-fde8c4d50f91?w=800&q=80',
            'Crispy chicken tossed with curry leaves and a spicy house seasoning.'
        ),
        (
            'Butter Chicken Masala',
            'Main Course',
            320,
            'https://images.unsplash.com/photo-1588166524941-3bf61a9c41db?w=800&q=80',
            'Tender chicken in a creamy tomato and butter gravy.'
        ),
        (
            'Paneer Butter Masala',
            'Main Course',
            280,
            'https://images.unsplash.com/photo-1631452180519-c014fe946bc7?w=800&q=80',
            'Soft paneer in a rich, mildly spiced tomato-butter sauce.'
        ),
        (
            'Butter Naan',
            'Breads & Naan',
            55,
            'https://images.unsplash.com/photo-1626074353765-517a681e40be?w=800&q=80',
            'Soft tandoor-baked naan brushed with butter.'
        ),
        (
            'Garlic Naan',
            'Breads & Naan',
            70,
            'https://images.unsplash.com/photo-1601050690597-df0568f70950?w=800&q=80',
            'Tandoor-baked naan topped with garlic and fresh herbs.'
        ),
        (
            'Gulab Jamun',
            'Desserts & Drinks',
            90,
            'https://images.unsplash.com/photo-1666190092159-3b4e2f6d2f07?w=800&q=80',
            'Soft milk dumplings served warm in fragrant sugar syrup.'
        ),
        (
            'Mango Lassi',
            'Desserts & Drinks',
            100,
            'https://images.unsplash.com/photo-1570197788417-0e82375c9371?w=800&q=80',
            'A chilled yogurt drink blended with sweet mango.'
        )
) as sample(name, category, price, image_url, description)
where not exists (
    select 1
    from public.menu_items existing
    where lower(btrim(existing.name)) = lower(btrim(sample.name))
        and lower(btrim(existing.category)) = lower(btrim(sample.category))
);
